package example;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;

class GreeterIT {
    @Test
    void greets() {
        assertEquals("hi", Greeter.greet());
    }
}
