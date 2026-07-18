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
if (!/^[a-z0-9]+(?:[._-][a-z0-9]+)*$/.test(name)) {
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

const updateJSONVersion = (path, rootPackage = false) => {
  const document = JSON.parse(readFileSync(path, "utf8"))
  let changed = document.version !== version
  if (mode === "verify" && changed) {
    throw new Error(`${path} version is ${document.version}; expected ${version}`)
  }
  document.version = version

  if (rootPackage && document.packages?.[""]) {
    const rootChanged = document.packages[""].version !== version
    if (mode === "verify" && rootChanged) {
      throw new Error(
        `${path} root package version is ${document.packages[""].version}; expected ${version}`,
      )
    }
    document.packages[""].version = version
    changed ||= rootChanged
  }

  if (mode === "apply" && changed) {
    writeFileSync(path, `${JSON.stringify(document, null, 2)}\n`)
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
