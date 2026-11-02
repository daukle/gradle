package com.example.logic;

import java.util.List;
import org.gradle.process.CommandLineArgumentProvider;

public final class Lint implements CommandLineArgumentProvider {
  @Override
  public Iterable<String> asArguments() {
    return List.of("-Xlint:none");
  }
}
