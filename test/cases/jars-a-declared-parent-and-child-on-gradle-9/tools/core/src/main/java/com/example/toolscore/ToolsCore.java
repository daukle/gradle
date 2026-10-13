package com.example.toolscore;

public final class ToolsCore {
  public static String name() {
    return com.example.tools.Tools.name() + "+" + com.example.core.Core.name();
  }
}
