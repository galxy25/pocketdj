package com.levi.pocketdj.data.credentials

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecretStoreMismatchTest {
    @Test fun transientKeystoreErrorsDoNotJustifyAWipe() {
        assertFalse(EncryptedSecretStore.isKeyMismatch(java.security.KeyStoreException("system error")))
        assertFalse(EncryptedSecretStore.isKeyMismatch(RuntimeException("boom", java.security.KeyStoreException("busy"))))
    }

    @Test fun badTagOrInvalidKeyIsAMismatch() {
        assertTrue(EncryptedSecretStore.isKeyMismatch(java.security.GeneralSecurityException("x", javax.crypto.AEADBadTagException())))
        assertTrue(EncryptedSecretStore.isKeyMismatch(RuntimeException(java.security.InvalidKeyException())))
        assertTrue(EncryptedSecretStore.isKeyMismatch(java.io.IOException("corrupt keyset")))
    }
}
