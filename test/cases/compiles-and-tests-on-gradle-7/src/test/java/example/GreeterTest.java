package example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class GreeterTest {
  @Test
  void greets() {
    assertEquals("hello world", new Greeter().greet("world"));
  }

  @Test
  void greetsAgain() {
    assertEquals("hello there", new Greeter().greet("there"));
  }
}
