// Copyright 2026 David Monagle / Monagle Pty Ltd
// SPDX-License-Identifier: MIT

import Testing

@testable import ConnectServer

@Suite("Protocol Detection")
struct ProtocolDetectionTests {
    // MARK: - Connect protocol

    @Test("application/json → Connect, JSON codec")
    func connectJSON() {
        let result = DetectedProtocol.detect(contentType: "application/json")
        #expect(result?.wireProtocol == .connect)
        #expect(result?.codec.contentType == "application/json")
    }

    @Test("application/proto → Connect, proto codec")
    func connectProto() {
        let result = DetectedProtocol.detect(contentType: "application/proto")
        #expect(result?.wireProtocol == .connect)
        #expect(result?.codec.contentType == "application/proto")
    }

    @Test("application/connect+json → Connect streaming, JSON codec")
    func connectStreamingJSON() {
        let result = DetectedProtocol.detect(contentType: "application/connect+json")
        #expect(result?.wireProtocol == .connect)
        #expect(result?.codec.contentType == "application/json")
    }

    @Test("application/connect+proto → Connect streaming, proto codec")
    func connectStreamingProto() {
        let result = DetectedProtocol.detect(contentType: "application/connect+proto")
        #expect(result?.wireProtocol == .connect)
        #expect(result?.codec.contentType == "application/proto")
    }

    // MARK: - gRPC-Web (must be checked before gRPC)

    @Test("application/grpc-web → gRPC-Web")
    func grpcWeb() {
        let result = DetectedProtocol.detect(contentType: "application/grpc-web")
        #expect(result?.wireProtocol == .grpcWeb)
    }

    @Test("application/grpc-web+proto → gRPC-Web")
    func grpcWebProto() {
        let result = DetectedProtocol.detect(contentType: "application/grpc-web+proto")
        #expect(result?.wireProtocol == .grpcWeb)
        #expect(result?.isTextEncoded == false)
    }

    @Test("application/grpc-web-text → gRPC-Web text mode")
    func grpcWebText() {
        let result = DetectedProtocol.detect(contentType: "application/grpc-web-text")
        #expect(result?.wireProtocol == .grpcWeb)
        #expect(result?.isTextEncoded == true)
    }

    @Test("application/grpc-web-text+proto → gRPC-Web text mode")
    func grpcWebTextProto() {
        let result = DetectedProtocol.detect(contentType: "application/grpc-web-text+proto")
        #expect(result?.wireProtocol == .grpcWeb)
        #expect(result?.isTextEncoded == true)
    }

    // MARK: - gRPC

    @Test("application/grpc → gRPC")
    func grpc() {
        let result = DetectedProtocol.detect(contentType: "application/grpc")
        #expect(result?.wireProtocol == .grpc)
    }

    @Test("application/grpc+proto → gRPC")
    func grpcProto() {
        let result = DetectedProtocol.detect(contentType: "application/grpc+proto")
        #expect(result?.wireProtocol == .grpc)
    }

    // MARK: - Rejection

    @Test("text/plain → nil (unsupported)")
    func textPlain() {
        #expect(DetectedProtocol.detect(contentType: "text/plain") == nil)
    }

    @Test("empty content type → nil")
    func empty() {
        #expect(DetectedProtocol.detect(contentType: "") == nil)
    }

    @Test("application/json is case-insensitive")
    func caseInsensitive() {
        let result = DetectedProtocol.detect(contentType: "Application/JSON")
        #expect(result?.wireProtocol == .connect)
    }
}
