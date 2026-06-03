package tech.kalkikgp.linkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PhoneNumberPolicyTest {
    @Test
    fun normalizesReadablePhoneNumbers() {
        assertEquals("+919876543210", PhoneNumberPolicy.normalizedDialNumber("+91 98765-43210"))
        assertEquals("2125551212", PhoneNumberPolicy.normalizedDialNumber("(212) 555-1212"))
    }

    @Test
    fun rejectsMmiAndNonPhonePayloads() {
        assertNull(PhoneNumberPolicy.normalizedDialNumber("*#06#"))
        assertNull(PhoneNumberPolicy.normalizedDialNumber("tel:2125551212"))
        assertNull(PhoneNumberPolicy.normalizedDialNumber("2125551212;123"))
    }

    @Test
    fun rejectsTooLongNumbers() {
        assertNull(PhoneNumberPolicy.normalizedDialNumber("+1234567890123456"))
    }
}
