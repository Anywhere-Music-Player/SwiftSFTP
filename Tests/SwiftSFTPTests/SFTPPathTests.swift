@testable import SwiftSFTP
import Testing

@Suite("Remote SFTP paths")
struct SFTPPathTests {
    @Test("preserves significant filename whitespace", arguments: [
        "/ spaced.bin ",
        " relative.bin ",
        " ",
        "/parent/ child /file ",
        "/\tname\n",
        "\nrelative\t",
        "/пісня 🎵 ",
    ])
    func preservesWhitespace(path: String) {
        #expect(path.sanitizePath == path)
    }

    @Test("preserves a relative whitespace-only directory component")
    func whitespaceDirectory() {
        #expect(" /file".sanitizePath == " /file")
    }

    @Test("keeps empty-path and component normalization")
    func normalizedComponents() {
        #expect("".sanitizePath == ".")
        #expect("/".sanitizePath == "/")
        #expect("/a//b/../c".sanitizePath == "/a/c")
        #expect("a/./b".sanitizePath == "a/b")
        #expect("../a".sanitizePath == "../a")
    }

    @Test("explicit Windows input conversion still trims input whitespace")
    func explicitWindowsConversion() {
        #expect("  C:/Users/alice  ".sftpPathFromWindows == "/C:/Users/alice")
        #expect("  ".sftpPathFromWindows == ".")
    }
}
