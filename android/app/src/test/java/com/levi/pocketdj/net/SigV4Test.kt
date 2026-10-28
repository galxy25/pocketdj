package com.levi.pocketdj.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** AWS Signature V4 S3 documentation vectors (examplebucket, 2013-05-24, us-east-1). */
class SigV4Test {
    private val creds = SigV4.Creds("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    private val epoch = 1369353600000L // 2013-05-24T00:00:00Z

    @Test fun amzDateFormat() = assertEquals("20130524T000000Z", SigV4.amzDate(epoch))

    @Test fun emptyPayloadHash() =
        assertEquals("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", SigV4.sha256Hex(ByteArray(0)))

    @Test fun getObjectWithRangeVector() {
        val s = SigV4.sign(
            "GET", "examplebucket.s3.amazonaws.com", "/test.txt", ByteArray(0), "us-east-1", "s3", creds, epoch,
            extraHeaders = mapOf("Range" to "bytes=0-9"),
        )
        assertEquals("host;range;x-amz-content-sha256;x-amz-date", s.signedHeaders)
        assertEquals("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", s.signature)
        assertTrue(s.headers.getValue("Authorization").startsWith(
            "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature="))
    }

    @Test fun putObjectVectorEncodesPathAndSignsExtraHeaders() {
        val s = SigV4.sign(
            "PUT", "examplebucket.s3.amazonaws.com", "/test\$file.text", "Welcome to Amazon S3.".toByteArray(),
            "us-east-1", "s3", creds, epoch,
            extraHeaders = mapOf("Date" to "Fri, 24 May 2013 00:00:00 GMT", "x-amz-storage-class" to "REDUCED_REDUNDANCY"),
        )
        assertTrue(s.canonicalRequest.startsWith("PUT\n/test%24file.text\n\n"))
        assertEquals("date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class", s.signedHeaders)
        assertEquals("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", s.signature)
    }

    @Test fun queryIsSortedAndEncoded() {
        val s = SigV4.sign("GET", "h", "/", ByteArray(0), "us-east-1", "s3", creds, epoch,
            query = mapOf("prefix" to "J", "max-keys" to "2"))
        assertEquals("GET\n/\nmax-keys=2&prefix=J\n", s.canonicalRequest.substringBefore("host:"))
    }

    @Test fun diagKeyPathStaysUnencoded() =
        assertEquals("/diag/android-ab12cd34/2026-10-27T01-02-03Z-b1.log",
            SigV4.encode("/diag/android-ab12cd34/2026-10-27T01-02-03Z-b1.log".replace(":", "-"), true))
}
