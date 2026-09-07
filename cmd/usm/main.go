package main

import (
	"os"
	"ubuntu-setup/internal/usm"
)

func main() { os.Exit(usm.Main(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }
