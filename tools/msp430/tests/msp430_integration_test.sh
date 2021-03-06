#!/bin/bash -e

echo "Installing Java dependencies..."
brew cask install homebrew/cask-versions/java8

echo "Installing bazel..."
brew update
brew install bazel

echo "Running test..."
bazel build //tools/msp430/tests:test_bin -s

echo "Test successful!"

