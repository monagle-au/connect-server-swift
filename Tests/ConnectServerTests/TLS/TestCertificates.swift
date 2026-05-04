// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

// Self-signed test certificate for TLS integration tests.
// CN=localhost, SAN: DNS:localhost, IP:127.0.0.1.
// 100-year expiry. Generated with:
//   openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=localhost" \
//     -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
//     -keyout test-key.pem -out test-cert.pem -days 36500
// The private key is intentionally embedded — this is for tests only.

enum TestCertificates {
    static let certificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIDJzCCAg+gAwIBAgIUWn5OVu/iKbyjWpCjJ6H9wYSjT5QwDQYJKoZIhvcNAQEL
        BQAwFDESMBAGA1UEAwwJbG9jYWxob3N0MCAXDTI2MDUwNDIzMDgxMFoYDzIxMjYw
        NDEwMjMwODEwWjAUMRIwEAYDVQQDDAlsb2NhbGhvc3QwggEiMA0GCSqGSIb3DQEB
        AQUAA4IBDwAwggEKAoIBAQC7wRqkA6jI93ZWMAIEND6lZyDqmIe2hIxw4DqvUjpC
        b+5LUBKh/WU4EaYy5KSj7rBAZIWSPut5Ay0tFb2+YNF3EpQJZUtZPgw0EcdKU6ur
        NFLkyGmrW4Pi5YrGg+aPzId0Z0WFLtwV9r/iTZhV8tuo/8uPiVcwZqpLFPNrWDoF
        ljdLMDuclUa0/+pgw5LXTD6JOMFTvvVtj2pyJdyGpnJ3AWIylmlU1ZzFm36WYyYn
        cYsJUgjVfpynjRVQ5KostXFzK6OGEaEXD3y1LxcCxsSNGFxPSiBttWKDZ62NzZa5
        LtroPbtmqS71E7MgBWBWCO1h5qJzFdFJnaoZ4YLEDzM5AgMBAAGjbzBtMB0GA1Ud
        DgQWBBR4ok+K3JCfYFqTjxKueujsmHIHITAfBgNVHSMEGDAWgBR4ok+K3JCfYFqT
        jxKueujsmHIHITAPBgNVHRMBAf8EBTADAQH/MBoGA1UdEQQTMBGCCWxvY2FsaG9z
        dIcEfwAAATANBgkqhkiG9w0BAQsFAAOCAQEAipV8opHbMZu+TTnP3SJf8UguK3r3
        BydFgPlD6CrNYysRD/eQUF+8Shu0o78p3gg3ptcYzQQGZY/3b7IWuNXGW+2Ie7UH
        uDw5wcDkPZ68tcPrw7ylFy6WRn5xtFdNGFQUY9tQ0sIb7na9OyuVB+9T41TElSHk
        gDKEdxCZUHZv/XZxHAeI3gsn7Qk1APvBpGnYOtf2phJ8oNtjeLBPt5oKjZ0QVKm2
        rd2MwFUHigFZD0uHnV6q1kdyGskK/6S1LnSrcPA1u1dz6BaiODSxCDeufOCtyfke
        OSpKUmXY4tVWEcgpjN2fiXpKYLqpsFxzmd0Xv/7Env7XEpctp0E4od9XPQ==
        -----END CERTIFICATE-----
        """

    static let privateKeyPEM = """
        -----BEGIN PRIVATE KEY-----
        MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQC7wRqkA6jI93ZW
        MAIEND6lZyDqmIe2hIxw4DqvUjpCb+5LUBKh/WU4EaYy5KSj7rBAZIWSPut5Ay0t
        Fb2+YNF3EpQJZUtZPgw0EcdKU6urNFLkyGmrW4Pi5YrGg+aPzId0Z0WFLtwV9r/i
        TZhV8tuo/8uPiVcwZqpLFPNrWDoFljdLMDuclUa0/+pgw5LXTD6JOMFTvvVtj2py
        JdyGpnJ3AWIylmlU1ZzFm36WYyYncYsJUgjVfpynjRVQ5KostXFzK6OGEaEXD3y1
        LxcCxsSNGFxPSiBttWKDZ62NzZa5LtroPbtmqS71E7MgBWBWCO1h5qJzFdFJnaoZ
        4YLEDzM5AgMBAAECggEAFpHw2CkZc+ktmFBGmcdHBZ6nWhQyckouUM5ft54wozZt
        5K9QQhliPtJ+Um1iblN97Au5c9ps95veZSZRLC7a10/MLHH5FBYNpP/DH4f94cOV
        OGvwKfmDGfZCj7kg8QXi/acBeDBpJBnIuNVfm+tpJQB08cEOkmKxE3wGBBAzz2Jp
        8MGkgNp4EOG/yrLBmcr7lnlSzAkQozEE917FKg/1U9G8UNSqJXQB80LghHaLqkZP
        VtTmmslaJqccaqWC1kWwfFxOqK3vDb3Vjc6tWQRZ/ER6tSTutK6A7GFblOtCvrhX
        rvyqj266oe8AxGjNHNXrggAddkdb5ky+GK6PTo+oAQKBgQDh9J25WWt9lk10amc8
        NMvaFscd0TeK1/QlbE1kgHOzQm0gUaWlnXP0miwuom58Z3Iy09ErELTR5S3BpE9g
        CJ9CXYORhOgf57Wgi6xu+64JIEtCuDCbej2us10N94ewtkrCDdTEoZDlmZXsK5j+
        aPAJdO4gnQ7V3CBM4pBbwihsAQKBgQDUuCR9fFzUOtGqiDX4Cqbi0dWfqfMGQ/V8
        TLNJLkB6uvuJa90ER3ULBHSCsLK4KsqgalTpUH3jCFMXJQ0EJ6CxC3npRejO/ttI
        wytjJCHSiGofWIsNTXApBjFPMdZrscP8zLfsklARxSzkSsRo06k8cX7jtoeW9SRA
        UqG2/JsnOQKBgQCr0oQN6j2fJqiHmlIeqldJ5IBN4EbIQifaPV0sy7Ev45dwOCYq
        pm0C2Co43DQATfm9RO2OPgoCgrAkzHm/oU7Z/JqMEfEiMeUfzJa3XpOdRP12IvJz
        iKVXL/XXJR/99OEsZ7AgRmwU7JHhIdYZwFqoFk7uZgBeCCJX1QHJhP+QAQKBgDfs
        ybssDQPHCwR4lyfFNScA39cASWJmT44EZEZjIJSjwCna79qGJuFkpHUPm40LwwX1
        rqlAfjhIIgA9v3ROLtMdH0oTFSgGnQQ+O5PvFe1R7ASdtMEkkM5YUHJvud3KeKpn
        8BsERITHgAvtFEIzE5VOiXu4q2EmxgcbMmT3eJsRAoGBAJ8wxJ3Wj7lXk0I1HH31
        4wOZv6FQItFIcj6kBHzA/fxXHRjH21s/KizL2BDCv+BVBdjFsn6BuKqn8oaF8Dqd
        Wg8AlDcdH8+E5FKOi58Sr+K8HVNmtb15TwJ06Wu5PphlaAy3Yld99Dc2113pJjjj
        8w12ebaWnob0pec0RZpGM3bT
        -----END PRIVATE KEY-----
        """
}
