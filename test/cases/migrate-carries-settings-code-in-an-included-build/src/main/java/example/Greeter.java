package example;

import example.greeting.Greeting;

public final class Greeter {
  public static String greet(String name) {
    return Greeting.text() + " " + name;
  }
}
