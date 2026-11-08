package main

import (
	"crypto/subtle"
	"os"
	"regexp"
	"strconv"
	"strings"
)

var (
	unitNameRE = regexp.MustCompile(`^[A-Za-z0-9@_][A-Za-z0-9@_.:\\-]*\.service$`)
	poolNameRE = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.:-]*$`)
)

func readFileTrim(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func splitLines(s string) []string {
	s = strings.TrimRight(s, "\n")
	if strings.TrimSpace(s) == "" {
		return nil
	}
	return strings.Split(s, "\n")
}

func parseInt64(s string) int64 {
	value, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return value
}

func parseFloat(s string) float64 {
	value, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return value
}

func parseUint64(s string) uint64 {
	value, _ := strconv.ParseUint(strings.TrimSpace(s), 10, 64)
	return value
}

func unquote(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && ((s[0] == '"' && s[len(s)-1] == '"') || (s[0] == '\'' && s[len(s)-1] == '\'')) {
		if unquoted, err := strconv.Unquote(s); err == nil {
			return unquoted
		}
		return s[1 : len(s)-1]
	}
	return s
}

func validToken(got, expected string) bool {
	if expected == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(got), []byte(expected)) == 1
}

func validUnitName(name string) bool {
	return unitNameRE.MatchString(name)
}

func validPoolName(name string) bool {
	return poolNameRE.MatchString(name)
}
