// Copyright 2026 The Bazel Go Rules Authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

func runWithSDK(args []string) error {
	if len(args) < 4 {
		return errors.New("usage: runwithsdk go sdk-root-file stdout-or-empty executable [args...]")
	}
	dir, err := filepath.Abs(filepath.Dir(args[0]))
	if err != nil {
		return err
	}
	if strings.ContainsRune(dir, os.PathListSeparator) {
		return fmt.Errorf("cannot put %q on PATH as a single directory", dir)
	}
	program, err := filepath.Abs(args[3])
	if err != nil {
		return err
	}
	cmd := exec.Command(program, args[4:]...)
	cmd.Args[0] = args[3]
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	cmd.Env = append(os.Environ(), "PATH="+dir)
	// A remote worker may materialize the go symlink as a regular file.
	// In that location go cannot infer its SDK from its executable path.
	if _, ok := os.LookupEnv("GOROOT"); !ok {
		root, err := filepath.Abs(filepath.Dir(args[1]))
		if err != nil {
			return err
		}
		cmd.Env = append(cmd.Env, "GOROOT="+root)
	}
	var out *os.File
	if args[2] != "" {
		out, err = os.Create(args[2])
		if err != nil {
			return err
		}
		cmd.Stdout = out
	}
	err = cmd.Run()
	if out != nil {
		if closeErr := out.Close(); err == nil {
			err = closeErr
		}
	}
	if exit, ok := err.(*exec.ExitError); ok {
		if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			os.Exit(128 + int(status.Signal()))
		}
		os.Exit(exit.ExitCode())
	}
	return err
}
