package example;

public final class Alpha {
  public static String greet() {
    return new org.opentest4j.AssertionFailedError("alpha").getMessage();
  }
}
