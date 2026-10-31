package com.example.app;

import com.example.contract.Greeting;

public final class App implements Greeting {
  public String text() {
    return "hello";
  }
}
