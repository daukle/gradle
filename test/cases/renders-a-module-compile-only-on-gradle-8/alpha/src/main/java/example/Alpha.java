package example;

public final class Alpha {
  public static String probe() {
    return new org.opentest4j.AssertionFailedError("probe").getMessage();
  }
}
