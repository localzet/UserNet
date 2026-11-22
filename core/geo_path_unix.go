//go:build !windows

package core

import "os"

func replaceGeoPath(source string, target string) error {
	return os.Rename(source, target)
}
