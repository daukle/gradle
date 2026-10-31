package example;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class GreeterTest {
  @Test
  public void greets() {
    assertEquals("hello ada", Greeter.greet("ada"));
  }
}
