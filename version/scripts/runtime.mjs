import { existsSync, readFileSync, writeFileSync } from "node:fs"
import { isAbsolute, relative, resolve, sep } from "node:path"
import { pathToFileURL } from "node:url"
import { spawnSync } from "node:child_process"

const [mode, projectInput, version, outputPath] = process.argv.slice(2)

if (!new Set(["apply", "verify"]).has(mode)) {
  throw new Error("runtime mode must be apply or verify")
}
if (!projectInput || !version) {
  throw new Error("runtime mode requires a project path and version")
}
if (mode === "apply" && !outputPath) {
  throw new Error("runtime apply mode requires an output path")
}

const project = resolve(projectInput)
const manifestPath = resolve(project, "adversary.yaml")
const manifest = readFileSync(manifestPath, "utf8")
const runtime = runtimeDefinition(manifest)
const files = []

if (runtime?.name === "node") {
  const sourcePath = resolve(project, "src/index.ts")
  if (existsSync(sourcePath)) {
    const source = readFileSync(sourcePath, "utf8")
    const synchronized = synchronizeAdversaryVersion(source, version, mode)
    if (mode === "apply" && synchronized.source !== source) {
      writeFileSync(sourcePath, synchronized.source)
    }
    if (synchronized.literalVersion) files.push(sourcePath)
  }

  if (mode === "apply") {
    buildNodeProject(project)
    await verifyBuiltRuntime(project, runtime.command, version)
    files.push(...trackedDistChanges(project))
  } else if (runtimeEntrypoint(project, runtime.command, false)) {
    await verifyBuiltRuntime(project, runtime.command, version)
  }
}

if (mode === "apply") {
  const normalized = [...new Set(files)].map((path) => workspacePath(path))
  writeFileSync(outputPath, `${JSON.stringify({ files: normalized })}\n`)
}

function runtimeDefinition(source) {
  const lines = source.split("\n")
  const runtimeLine = lines.findIndex((line) => /^runtime:\s*(?:#.*)?$/.test(line))
  if (runtimeLine < 0) return undefined

  const block = []
  for (let index = runtimeLine + 1; index < lines.length; index += 1) {
    const line = lines[index]
    if (line && !/^\s/.test(line)) break
    block.push(line)
  }
  const nameLine = block.find((line) => /^\s+name:\s*/.test(line))
  const name = nameLine ? yamlScalar(nameLine.replace(/^\s+name:\s*/, "")) : undefined
  const commandLine = block.findIndex((line) => /^\s+command:\s*(?:#.*)?$/.test(line))
  const command = []
  if (commandLine >= 0) {
    const indent = block[commandLine].match(/^\s*/)[0].length
    for (let index = commandLine + 1; index < block.length; index += 1) {
      const line = block[index]
      if (!line.trim() || /^\s*#/.test(line)) continue
      const currentIndent = line.match(/^\s*/)[0].length
      if (currentIndent <= indent) break
      const item = line.match(/^\s*-\s*(.*?)\s*(?:#.*)?$/)
      if (!item) throw new Error("node runtime command must be a simple YAML string list")
      command.push(yamlScalar(item[1]))
    }
  }
  return { name, command }
}

function yamlScalar(value) {
  const trimmed = value.trim()
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'")))
  ) return trimmed.slice(1, -1)
  return trimmed
}

function synchronizeAdversaryVersion(source, expected, operation) {
  const tokens = tokenize(source)
  const initializers = []
  for (let index = 0; index + 3 < tokens.length; index += 1) {
    if (
      tokens[index].value === "new" && tokens[index + 1].value === "Adversary" &&
      tokens[index + 2].value === "(" && tokens[index + 3].value === "{"
    ) initializers.push(index + 3)
  }
  if (initializers.length === 0) return { source, literalVersion: false }
  if (initializers.length > 1) {
    throw new Error("src/index.ts has multiple Adversary object initializers; runtime version cannot be synchronized safely")
  }

  const opening = initializers[0]
  let depth = 1
  let versionToken
  for (let index = opening + 1; index < tokens.length && depth > 0; index += 1) {
    const token = tokens[index]
    if (["{", "[", "("].includes(token.value)) depth += 1
    if (["}", "]", ")"].includes(token.value)) depth -= 1
    if (depth !== 1 || token.value !== "version") continue
    const next = tokens[index + 1]
    if (next?.value === ":") versionToken = tokens[index + 2]
    else if (next?.value === "," || next?.value === "}") versionToken = token
    break
  }

  // Computed/shorthand/omitted versions are not rewritten. The built-artifact
  // check below is the authority, allowing package inference without guessing.
  if (versionToken?.kind !== "string") return { source, literalVersion: false }
  if (operation === "verify" && versionToken.value !== expected) {
    throw new Error(`src/index.ts runtime version is ${versionToken.value}; expected ${expected}`)
  }
  if (versionToken.value === expected) return { source, literalVersion: true }
  return {
    source: `${source.slice(0, versionToken.start)}${JSON.stringify(expected)}${source.slice(versionToken.end)}`,
    literalVersion: true,
  }
}

function tokenize(source) {
  const tokens = []
  let index = 0
  while (index < source.length) {
    const char = source[index]
    if (/\s/.test(char)) {
      index += 1
      continue
    }
    if (char === "/" && source[index + 1] === "/") {
      index = source.indexOf("\n", index + 2)
      if (index < 0) break
      continue
    }
    if (char === "/" && source[index + 1] === "*") {
      const end = source.indexOf("*/", index + 2)
      if (end < 0) throw new Error("unterminated block comment in src/index.ts")
      index = end + 2
      continue
    }
    if (char === "/") {
      const end = regexLiteralEnd(source, index)
      // JavaScript's division-vs-regex ambiguity cannot be resolved from the
      // preceding token alone (for example, a regex statement may follow an
      // `if (...)` condition). Recognize normal regex contexts structurally,
      // and conservatively mask any ambiguous slash span containing the exact
      // constructor shape we edit. In the latter case verification remains the
      // authority: overlooking executable code fails closed, while regex text
      // is never rewritten.
      if (end !== undefined && (
        canStartRegex(tokens) || containsAdversaryInitializer(source.slice(index, end))
      )) {
        tokens.push({ kind: "regex", value: source.slice(index, end), start: index, end })
        index = end
        continue
      }
    }
    if (char === '"' || char === "'" || char === "`") {
      const start = index
      const quote = char
      index += 1
      let value = ""
      while (index < source.length) {
        if (source[index] === "\\") {
          value += source.slice(index, index + 2)
          index += 2
          continue
        }
        if (source[index] === quote) {
          index += 1
          tokens.push({ kind: quote === "`" ? "template" : "string", value, start, end: index })
          break
        }
        value += source[index]
        index += 1
      }
      if (tokens.at(-1)?.start !== start) throw new Error("unterminated string in src/index.ts")
      continue
    }
    if (/[A-Za-z_$]/.test(char)) {
      const start = index
      index += 1
      while (/[A-Za-z0-9_$]/.test(source[index] ?? "")) index += 1
      tokens.push({ kind: "identifier", value: source.slice(start, index), start, end: index })
      continue
    }
    tokens.push({ kind: "punctuation", value: char, start: index, end: index + 1 })
    index += 1
  }
  return tokens
}

function canStartRegex(tokens) {
  const previous = tokens.at(-1)
  if (!previous) return true
  if (previous.value === ")" && closesControlCondition(tokens)) return true
  if (previous.kind === "identifier") {
    return new Set([
      "await", "case", "delete", "do", "else", "in", "instanceof", "of",
      "return", "throw", "typeof", "void", "yield",
    ]).has(previous.value)
  }
  if (previous.kind !== "punctuation") return false
  return "([{,;:=!?&|+-*%^~<>".includes(previous.value)
}

function closesControlCondition(tokens) {
  let depth = 0
  for (let index = tokens.length - 1; index >= 0; index -= 1) {
    if (tokens[index].value === ")") depth += 1
    if (tokens[index].value !== "(") continue
    depth -= 1
    if (depth !== 0) continue
    const keyword = tokens[index - 1]
    return keyword?.kind === "identifier" &&
      new Set(["catch", "for", "if", "switch", "while", "with"]).has(keyword.value)
  }
  return false
}

function containsAdversaryInitializer(source) {
  return /\bnew\s+Adversary\s*\(\s*\{/.test(source)
}

function regexLiteralEnd(source, start) {
  let inCharacterClass = false
  for (let index = start + 1; index < source.length; index += 1) {
    const char = source[index]
    if (char === "\\") {
      index += 1
      continue
    }
    if (char === "\n" || char === "\r") return undefined
    if (char === "[") {
      inCharacterClass = true
      continue
    }
    if (char === "]" && inCharacterClass) {
      inCharacterClass = false
      continue
    }
    if (char !== "/" || inCharacterClass) continue

    index += 1
    while (/[A-Za-z]/.test(source[index] ?? "")) index += 1
    return index
  }
  return undefined
}

function buildNodeProject(directory) {
  const packagePath = resolve(directory, "package.json")
  if (!existsSync(packagePath)) return
  const packageDocument = JSON.parse(readFileSync(packagePath, "utf8"))
  const manager = packageManager(directory)
  if (manager.install) run(manager.command, manager.install, directory)
  if (packageDocument.scripts?.build) run(manager.command, [...manager.prefix, "run", "build"], directory)
}

function packageManager(directory) {
  if (existsSync(resolve(directory, "package-lock.json"))) {
    return { command: "npm", install: ["ci"], prefix: [] }
  }
  if (existsSync(resolve(directory, "pnpm-lock.yaml"))) {
    return { command: "corepack", install: ["pnpm", "install", "--frozen-lockfile"], prefix: ["pnpm"] }
  }
  if (existsSync(resolve(directory, "yarn.lock"))) {
    return { command: "corepack", install: ["yarn", "install", "--frozen-lockfile"], prefix: ["yarn"] }
  }
  return { command: "npm", install: undefined, prefix: [] }
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit", env: process.env })
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`${command} ${args.join(" ")} failed with exit code ${result.status}`)
}

async function verifyBuiltRuntime(directory, command, expected) {
  const entrypoint = runtimeEntrypoint(directory, command, true)
  const runtimeModule = await import(`${pathToFileURL(entrypoint).href}?adversary-version-check=${Date.now()}`)
  if (typeof runtimeModule.createApp !== "function") {
    throw new Error(`${relative(directory, entrypoint)} must export createApp() so release runtime identity can be verified`)
  }
  const app = await runtimeModule.createApp()
  if (app?.version !== expected) {
    throw new Error(`${relative(directory, entrypoint)} reports adversary version ${String(app?.version)}; expected ${expected}`)
  }
}

function runtimeEntrypoint(directory, command, required) {
  let executable = command.find((item) => /\.(?:c?m?js)$/.test(item))
  if (!executable && command.length === 1 && !command[0].startsWith("-")) executable = command[0]
  if (!executable || isAbsolute(executable) || executable.split(/[\\/]/).includes("..")) {
    if (!required) return undefined
    throw new Error("node runtime command must identify a project-relative JavaScript entrypoint")
  }
  const entrypoint = resolve(directory, executable)
  if (!existsSync(entrypoint)) {
    if (!required) return undefined
    throw new Error(`node runtime entrypoint was not built: ${executable}`)
  }
  return entrypoint
}

function trackedDistChanges(directory) {
  const result = spawnSync("git", ["diff", "--name-only", "--", "dist"], {
    cwd: directory,
    encoding: "utf8",
  })
  if (result.status !== 0) return []
  return result.stdout.split("\n").filter(Boolean).map((path) => resolve(directory, path))
}

function workspacePath(path) {
  const value = relative(process.cwd(), path).split(sep).join("/")
  if (!value || value.startsWith("../")) {
    throw new Error(`release runtime path is outside the workspace: ${path}`)
  }
  return value
}
