package dev.narad.narad_client

import org.junit.Assert.*
import org.junit.Test

class PhoneBridgeTest {
    @Test fun phoneNumbersNormalizeWithoutExecutingDialCodes() {
        assertEquals("+1234567890",PhoneBridge.number("+1 (234) 567-890"))
        assertEquals("12345",PhoneBridge.number("12345"))
    }
    @Test fun remoteNumbersRejectUssdUrisAndControlCharacters() {
        for(number in listOf("*21*12345#","#31#12345","tel:12345","123\n45","++123","","1","123456789012345678901")) {
            try {PhoneBridge.number(number);fail("Unexpected accepted number")}
            catch(_:IllegalArgumentException){}
        }
    }
}
