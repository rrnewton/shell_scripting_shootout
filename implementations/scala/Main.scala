//> using scala "3.8.4"
//> using dep "com.lihaoyi::upickle:4.4.3"
//> using options "-Werror" "-Wunused:all" "-deprecation" "-feature" "-unchecked"

import java.io.PrintStream
import java.nio.file.Path
import scala.util.control.NonFatal

final case class CliOptions(mode: String, input: Path, gitDir: Option[Path], human: Boolean)

object Program:
  val usage: String =
    """Usage:
      |  pr-plan pure --input FILE [--human]
      |  pr-plan git --input FILE --git-dir DIR [--human]
      |
      |Build deterministic pull-request conflict and landing plans.
      |""".stripMargin

  private def parse(arguments: Vector[String]): Either[(Int, String, Boolean), CliOptions] =
    arguments match
      case Vector() => Left((2, usage, false))
      case Vector("--help" | "-h") => Left((0, usage, true))
      case mode +: rest if mode == "pure" || mode == "git" =>
        if rest == Vector("--help") || rest == Vector("-h") then Left((0, usage, true))
        else
          var input: Option[Path] = None
          var gitDir: Option[Path] = None
          var human = false
          var index = 0
          while index < rest.size do
            rest(index) match
              case "--input" if input.isEmpty && index + 1 < rest.size =>
                input = Some(Path.of(rest(index + 1)))
                index += 2
              case "--git-dir" if mode == "git" && gitDir.isEmpty && index + 1 < rest.size =>
                gitDir = Some(Path.of(rest(index + 1)))
                index += 2
              case "--human" if !human =>
                human = true
                index += 1
              case option => return Left((2, s"pr-plan: error: unexpected or invalid argument '$option'\n$usage", false))
          input match
            case None => Left((2, "pr-plan: error: --input is required\n", false))
            case Some(_) if mode == "git" && gitDir.isEmpty =>
              Left((2, "pr-plan: error: --git-dir is required\n", false))
            case Some(inputPath) => Right(CliOptions(mode, inputPath, gitDir, human))
      case mode +: _ => Left((2, s"pr-plan: error: unknown mode '$mode'\n$usage", false))
      case _         => Left((2, usage, false))

  def run(arguments: Vector[String], stdout: PrintStream, stderr: PrintStream): Int =
    parse(arguments) match
      case Left((status, message, toStdout)) =>
        if toStdout then stdout.print(message) else stderr.print(message)
        status
      case Right(options) =>
        try
          val raw = Validation.load(options.input, options.mode)
          val input = options.gitDir match
            case Some(path) => GitAnalysis.analyze(raw, path)
            case None       => raw
          val plan = Planner.build(input)
          stdout.print(if options.human then Render.human(plan) else Render.json(plan))
          0
        catch
          case NonFatal(error) =>
            stderr.println(s"pr-plan: error: ${Option(error.getMessage).getOrElse(error.getClass.getSimpleName)}")
            1

@main def prPlan(arguments: String*): Unit =
  val status = Program.run(arguments.toVector, System.out, System.err)
  if status != 0 then System.exit(status)
