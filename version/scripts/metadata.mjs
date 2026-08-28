import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { relative, resolve, sep } from "node:path"

const [mode, projectInput, version, syncNpm] = process.argv.slice(2)

if (!new Set(["apply", "verify"]).has(mode)) {
  throw new Error("metadata mode must be apply or verify")
}
if (!new Set(["auto", "true", "false"]).has(syncNpm)) {
  throw new Error("sync-npm must be auto, true, or false")
}

const project = resolve(projectInput)
const manifestPath = resolve(project, "adversary.yaml")
if (!existsSync(manifestPath)) {
  throw new Error(`adversary manifest does not exist: ${manifestPath}`)
}

const manifest = readFileSync(manifestPath, "utf8")
const names = manifest.match(/^name:[\t ]*(.*)$/gm) ?? []
const versions = manifest.match(/^version:[\t ]*(.*)$/gm) ?? []
if (names.length !== 1 || versions.length !== 1) {
  throw new Error("adversary.yaml must contain exactly one top-level name and version")
}

const scalar = (line, key) => {
  const value = line.replace(new RegExp(`^${key}:[\\t ]*`), "").trim()
  if (
    value.length >= 2 &&
    ((value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'")))
  ) {
    return value.slice(1, -1)
  }
  return value
}

const name = scalar(names[0], "name")
// OCI repository paths may contain any number of segments. Hosted releases use
// team/taxonomy/name (for example adversarylabs/go/security).
if (
  !/^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:\/[a-z0-9]+(?:[._-][a-z0-9]+)*)*$/.test(
    name,
  )
) {
  throw new Error(`adversary name is not an OCI-compatible repository name: ${name}`)
}

const currentManifestVersion = scalar(versions[0], "version")
if (mode === "verify" && currentManifestVersion !== version) {
  throw new Error(`adversary.yaml version is ${currentManifestVersion}; expected ${version}`)
}
if (mode === "apply" && currentManifestVersion !== version) {
  writeFileSync(
    manifestPath,
    manifest.replace(/^version:[\t ]*.*$/m, `version: ${version}`),
  )
}

const files = [manifestPath]
const packagePath = resolve(project, "package.json")
const lockPath = resolve(project, "package-lock.json")
const hasPackage = existsSync(packagePath)
const hasLock = existsSync(lockPath)

if (syncNpm === "true" && !hasPackage) {
  throw new Error("sync-npm is true but package.json does not exist")
}
if (hasLock && !hasPackage) {
  throw new Error("package-lock.json exists without package.json")
}

const synchronizePackage = syncNpm === "true" || (syncNpm === "auto" && hasPackage)

const locateJSONStringValues = (source, targetPaths) => {
  const targets = new Set(targetPaths.map((path) => JSON.stringify(path)))
  const locations = new Map()
  let index = 0

  const whitespace = () => {
    while (/\s/.test(source[index] ?? "")) index += 1
  }
  const stringToken = () => {
    whitespace()
    if (source[index] !== '"') throw new Error("expected a JSON string")
    const start = index
    index += 1
    while (index < source.length) {
      if (source[index] === "\\") {
        index += 2
        continue
      }
      if (source[index] === '"') {
        index += 1
        const end = index
        return { start, end, value: JSON.parse(source.slice(start, end)) }
      }
      index += 1
    }
    throw new Error("unterminated JSON string")
  }
  const value = (path) => {
    whitespace()
    if (source[index] === "{") {
      index += 1
      whitespace()
      if (source[index] === "}") {
        index += 1
        return
      }
      while (index < source.length) {
        const key = stringToken().value
        whitespace()
        if (source[index] !== ":") throw new Error("expected a JSON object colon")
        index += 1
        value([...path, key])
        whitespace()
        if (source[index] === "}") {
          index += 1
          return
        }
        if (source[index] !== ",") throw new Error("expected a JSON object comma")
        index += 1
      }
      throw new Error("unterminated JSON object")
    }
    if (source[index] === "[") {
      index += 1
      whitespace()
      if (source[index] === "]") {
        index += 1
        return
      }
      let item = 0
      while (index < source.length) {
        value([...path, String(item)])
        item += 1
        whitespace()
        if (source[index] === "]") {
          index += 1
          return
        }
        if (source[index] !== ",") throw new Error("expected a JSON array comma")
        index += 1
      }
      throw new Error("unterminated JSON array")
    }
    if (source[index] === '"') {
      const token = stringToken()
      const pathKey = JSON.stringify(path)
      if (targets.has(pathKey)) {
        if (locations.has(pathKey)) throw new Error(`duplicate JSON path: ${path.join(".")}`)
        locations.set(pathKey, token)
      }
      return
    }

    const start = index
    while (index < source.length && !/[\s,}\]]/.test(source[index])) index += 1
    if (start === index) throw new Error("expected a JSON value")
    JSON.parse(source.slice(start, index))
  }

  value([])
  whitespace()
  if (index !== source.length) throw new Error("unexpected data after JSON document")
  return locations
}

const replaceJSONStringValues = (source, replacements) => {
  const locations = locateJSONStringValues(source, [...replacements.keys()])
  const edits = []
  for (const [path, replacement] of replacements) {
    const location = locations.get(JSON.stringify(path))
    if (!location) throw new Error(`JSON string path does not exist: ${path.join(".")}`)
    edits.push({ ...location, replacement: JSON.stringify(replacement) })
  }
  edits.sort((left, right) => right.start - left.start)
  return edits.reduce(
    (result, edit) =>
      `${result.slice(0, edit.start)}${edit.replacement}${result.slice(edit.end)}`,
    source,
  )
}

const updateJSONVersion = (path, rootPackage = false) => {
  const source = readFileSync(path, "utf8")
  const document = JSON.parse(source)
  let changed = document.version !== version
  if (mode === "verify" && changed) {
    throw new Error(`${path} version is ${document.version}; expected ${version}`)
  }
  document.version = version
  const replacements = new Map([[['version'], version]])

  if (rootPackage && document.packages?.[""]) {
    const rootChanged = document.packages[""].version !== version
    if (mode === "verify" && rootChanged) {
      throw new Error(
        `${path} root package version is ${document.packages[""].version}; expected ${version}`,
      )
    }
    document.packages[""].version = version
    changed ||= rootChanged
    replacements.set(["packages", "", "version"], version)
  }

  if (mode === "apply" && changed) {
    writeFileSync(path, replaceJSONStringValues(source, replacements))
  }
}

if (synchronizePackage) {
  updateJSONVersion(packagePath)
  files.push(packagePath)
  if (hasLock) {
    updateJSONVersion(lockPath, true)
    files.push(lockPath)
  }
}

if (mode === "apply") {
  console.log(name)
  for (const path of files) {
    const value = relative(process.cwd(), path).split(sep).join("/")
    if (!value || value.startsWith("../")) {
      throw new Error(`release metadata path is outside the workspace: ${path}`)
    }
    console.log(value)
  }
}
