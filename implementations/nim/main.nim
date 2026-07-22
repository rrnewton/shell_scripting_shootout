import std/os

import git_analysis, planner, render, validation

const usageText* = """Usage:
  pr-plan pure --input FILE [--human]
  pr-plan git --input FILE --git-dir DIR [--human]

Build deterministic pull-request conflict and landing plans.
"""

type
  CliError = object of CatchableError

  Options = object
    mode: InputMode
    input: string
    gitDir: string
    human: bool

proc cliError(message: string): ref CliError =
  newException(CliError, message)

proc parseOptions(arguments: seq[string]): Options =
  if arguments.len == 0:
    raise cliError("missing mode")
  case arguments[0]
  of "pure": result.mode = pureMode
  of "git": result.mode = gitMode
  else: raise cliError("unknown mode \"" & arguments[0] & "\"")

  var index = 1
  while index < arguments.len:
    case arguments[index]
    of "--input":
      if result.input.len > 0:
        raise cliError("--input may only be supplied once")
      inc(index)
      if index >= arguments.len:
        raise cliError("--input requires a value")
      result.input = arguments[index]
    of "--git-dir":
      if result.mode != gitMode:
        raise cliError("--git-dir is only valid in git mode")
      if result.gitDir.len > 0:
        raise cliError("--git-dir may only be supplied once")
      inc(index)
      if index >= arguments.len:
        raise cliError("--git-dir requires a value")
      result.gitDir = arguments[index]
    of "--human":
      if result.human:
        raise cliError("--human may only be supplied once")
      result.human = true
    else:
      raise cliError("unexpected argument \"" & arguments[index] & "\"")
    inc(index)
  if result.input.len == 0:
    raise cliError("--input is required")
  if result.mode == gitMode and result.gitDir.len == 0:
    raise cliError("--git-dir is required")

proc run*(arguments: seq[string]): int =
  if arguments.len > 0 and arguments[0] in ["--help", "-h"]:
    stdout.write(usageText)
    return 0
  if arguments.len > 1 and arguments[1] in ["--help", "-h"]:
    stdout.write(usageText)
    return 0
  try:
    let options = parseOptions(arguments)
    var data = loadDocument(options.input, options.mode)
    if options.mode == gitMode:
      data = analyzeRepository(data, options.gitDir)
    let output = if options.human:
        renderHuman(makePlan(data))
      else:
        renderJson(makePlan(data))
    stdout.write(output)
    0
  except CliError as error:
    stderr.write("pr-plan: error: " & error.msg & "\n")
    stderr.write(usageText)
    2
  except InputError, GitError:
    stderr.write("pr-plan: error: " & getCurrentExceptionMsg() & "\n")
    1
  except CatchableError:
    stderr.write("pr-plan: error: " & getCurrentExceptionMsg() & "\n")
    1

when isMainModule:
  quit(run(commandLineParams()))
