package example.app;

import example.fixtures.Sample;

public final class EchoCheck {
  public static boolean holds() {
    return Echo.echo(Sample.value()).equals(Sample.value());
  }
}
