package example;

public final class Beta {
  public static String probe() {
    return new org.opentest4j.AssertionFailedError("probe").getMessage();
  }
}
