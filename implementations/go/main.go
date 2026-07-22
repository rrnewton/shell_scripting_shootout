package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"syscall"
)

const usageText = `Usage:
  pr-plan pure --input FILE [--human]
  pr-plan git --input FILE --git-dir DIR [--human]

Build deterministic pull-request conflict and landing plans.
`

type options struct {
	mode   string
	input  string
	gitDir string
	human  bool
}

func parseOptions(arguments []string, stdout, stderr io.Writer) (options, int) {
	if len(arguments) == 0 {
		fmt.Fprint(stderr, usageText)
		return options{}, 2
	}
	if arguments[0] == "--help" || arguments[0] == "-h" {
		fmt.Fprint(stdout, usageText)
		return options{}, 0
	}
	mode := arguments[0]
	if mode != "pure" && mode != "git" {
		fmt.Fprintf(stderr, "pr-plan: error: unknown mode %q\n", mode)
		fmt.Fprint(stderr, usageText)
		return options{}, 2
	}
	flags := flag.NewFlagSet(mode, flag.ContinueOnError)
	flags.SetOutput(stderr)
	input := flags.String("input", "", "input JSON file")
	human := flags.Bool("human", false, "render human-readable output")
	gitDir := ""
	if mode == "git" {
		flags.StringVar(&gitDir, "git-dir", "", "local Git repository")
	}
	flags.Usage = func() { fmt.Fprint(stderr, usageText) }
	if err := flags.Parse(arguments[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return options{}, 0
		}
		return options{}, 2
	}
	if flags.NArg() != 0 {
		fmt.Fprintf(stderr, "pr-plan: error: unexpected argument %q\n", flags.Arg(0))
		return options{}, 2
	}
	if *input == "" {
		fmt.Fprintln(stderr, "pr-plan: error: --input is required")
		return options{}, 2
	}
	if mode == "git" && gitDir == "" {
		fmt.Fprintln(stderr, "pr-plan: error: --git-dir is required")
		return options{}, 2
	}
	return options{mode: mode, input: *input, gitDir: gitDir, human: *human}, -1
}

func run(arguments []string, stdout, stderr io.Writer) int {
	options, status := parseOptions(arguments, stdout, stderr)
	if status >= 0 {
		return status
	}
	data, err := loadDocument(options.input, options.mode)
	if err == nil && options.mode == "git" {
		data, err = analyzeRepository(data, options.gitDir)
	}
	if err != nil {
		fmt.Fprintf(stderr, "pr-plan: error: %v\n", err)
		return 1
	}
	plan := makePlan(data)
	var output []byte
	if options.human {
		output = renderHuman(plan)
	} else {
		output, err = renderJSON(plan)
		if err != nil {
			fmt.Fprintf(stderr, "pr-plan: error: could not encode result: %v\n", err)
			return 1
		}
	}
	if _, err := stdout.Write(output); err != nil && !errors.Is(err, syscall.EPIPE) {
		fmt.Fprintf(stderr, "pr-plan: error: could not write output: %v\n", err)
		return 1
	}
	return 0
}

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}
