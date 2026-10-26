package example;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertEquals;

class GreeterTest {
  @Test
  void greetsTheFirstFixtureName() {
    assertEquals("hello world", new Greeter().greet(Names.first()));
  }

  @Test
  void greetsTheSecondFixtureName() {
    assertEquals("hello there", new Greeter().greet(Names.second()));
  }
}
