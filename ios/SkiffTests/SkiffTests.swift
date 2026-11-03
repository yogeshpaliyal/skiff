import Security
import XCTest
@testable import Skiff

/** The Android app's unit tests (app/src/test), for the same logic in Swift: the two apps must read links alike. */
final class TitleSourcesTests: XCTestCase {
    func testFindsTheSiteOfALink() {
        XCTAssertEqual(TitleSources.of(" https://trakt.tv/shows/breaking-bad/seasons/1/episodes/4 ")?.key, "trakt")
        XCTAssertEqual(TitleSources.of("https://simkl.com/tv/17465/game-of-thrones")?.key, "simkl")
        XCTAssertEqual(TitleSources.of("https://letterboxd.com/film/the-matrix/")?.key, "letterboxd")
        XCTAssertEqual(TitleSources.of("https://boxd.it/2bnu")?.key, "letterboxd")
        XCTAssertEqual(TitleSources.of("https://mdblist.com/show/tt0903747")?.key, "mdblist")
        XCTAssertEqual(TitleSources.of("https://wetrakr.com/shows/1391953")?.key, "wetrakr")
    }

    func testLeavesImdbAndOtherLinksAlone() {
        XCTAssertNil(TitleSources.of("https://www.imdb.com/title/tt0120737/"))
        XCTAssertNil(TitleSources.of("https://www.youtube.com/watch?v=x"))
        XCTAssertNil(TitleSources.of("tt0120737"))
    }

    func testASharedSiteLinkIsLookedUpEvenWithAnImdbIdInIt() {
        XCTAssertEqual(
            Title.fromShared(text: "https://mdblist.com/show/tt0903747", subject: "Breaking Bad"),
            Title.Shared(imdbId: "", name: "Breaking Bad", series: nil, link: "https://mdblist.com/show/tt0903747")
        )
        XCTAssertEqual(Title.fromShared(text: "https://www.imdb.com/title/tt0120737/", subject: nil)?.imdbId, "tt0120737")
    }

    func testReadsTheImdbAppsShare() {
        let s = Title.fromShared(text: "Agent Kim Reactivated (TV Series 2025– ) ⭐ 7.6 | Action https://m.imdb.com/title/tt42127457/", subject: nil)
        XCTAssertEqual(s, Title.Shared(imdbId: "tt42127457", name: "Agent Kim Reactivated", series: true))
    }

    func testSearchesTheNameWhenNotFound() {
        XCTAssertEqual(Trakt().searchFor("https://trakt.tv/movies/the-lord-of-the-rings-2001"), "the lord of the rings")
        XCTAssertEqual(Simkl().searchFor("https://simkl.com/tv/17465/game-of-thrones"), "game of thrones")
        XCTAssertEqual(Letterboxd().searchFor("https://letterboxd.com/film/the-gift-2000/"), "the gift")
        XCTAssertNil(Wetrakr().searchFor("https://wetrakr.com/shows/1391953"))
    }

    func testTrakt() {
        XCTAssertEqual(Trakt.parse("https://trakt.tv/shows/breaking-bad"), Trakt.Ref(slug: "breaking-bad", series: true))
        XCTAssertEqual(Trakt.parse("https://app.trakt.tv/shows/breaking-bad/seasons/2"), Trakt.Ref(slug: "breaking-bad", series: true, season: 2))
        XCTAssertEqual(Trakt.parse("https://www.trakt.tv/shows/breaking-bad/seasons/1/episodes/4"),
                       Trakt.Ref(slug: "breaking-bad", series: true, season: 1, episode: 4))
        XCTAssertNil(Trakt.parse("https://www.imdb.com/title/tt0120737/"))
        XCTAssertNil(Trakt.parse("https://trakt.tv/users/someone/history"))
        XCTAssertNil(Trakt.parse("https://nottrakt.tv/movies/x"))
        XCTAssertEqual(TitleSources.imdbLinkIn(#"<a href="https://www.imdb.com/title/tt0120737/">IMDb</a>"#), "tt0120737")
        XCTAssertNil(TitleSources.imdbLinkIn("<html>No links</html>"))
        XCTAssertEqual(TitleSources.nameAndYear("the-lord-of-the-rings-2001").name, "the lord of the rings")
        XCTAssertEqual(TitleSources.nameAndYear("the-lord-of-the-rings-2001").year, "2001")
        XCTAssertNil(TitleSources.nameAndYear("breaking-bad").year)
    }

    func testSimkl() {
        XCTAssertEqual(Simkl.parse("https://simkl.com/movies/53536/terminator-3-rise-of-the-machines"),
                       Simkl.Ref(type: "movies", id: "53536", slug: "terminator-3-rise-of-the-machines"))
        XCTAssertEqual(Simkl.parse("https://simkl.com/tv/17465"), Simkl.Ref(type: "tv", id: "17465", slug: nil))
        XCTAssertEqual(Simkl.parse("https://simkl.com/tv/17465/game-of-thrones/season-1/episode-4/"),
                       Simkl.Ref(type: "tv", id: "17465", slug: "game-of-thrones", season: 1, episode: 4))
        XCTAssertNil(Simkl.parse("https://simkl.com/search/?q=matrix"))
        let anime = #"{"title":"Shingeki no Kyojin","type":"anime","ids":{"imdb":"tt2560140"},"anime_type":"tv","relations":[{"anime_type":"movie"}]}"#
        XCTAssertEqual(Simkl.read(anime, type: "anime")?.0, "tt2560140")
        XCTAssertEqual(Simkl.read(anime, type: "anime")?.1, true)
        let animeMovie = #"{"title":"Your Name.","type":"anime","ids":{"imdb":"tt5311514"},"anime_type":"movie"}"#
        XCTAssertEqual(Simkl.read(animeMovie, type: "anime")?.1, false)
        XCTAssertNil(Simkl.read(#"{"title":"x","ids":{"simkl":1}}"#, type: "tv"))
    }

    func testWetrakrMdbListLetterboxd() {
        XCTAssertEqual(Wetrakr.parse("https://wetrakr.com/shows/1391953/seasons/1/episodes/4"),
                       Wetrakr.Ref(id: "1391953", series: true, season: 1, episode: 4))
        XCTAssertNil(Wetrakr.parse("https://wetrakr.com/shows/trending"))
        XCTAssertEqual(Wetrakr.imdbIdIn(#"{"ids":{"tmdb":{"id":1396},"imdb":{"id":"tt0903747"}}}"#), "tt0903747")
        XCTAssertEqual(MdbList.parse("https://mdblist.com/show/tt0903747"), MdbList.Ref(series: true, imdbId: "tt0903747"))
        XCTAssertEqual(MdbList.parse("https://mdblist.com/show/3xzbl-carrie"), MdbList.Ref(series: true, slug: "carrie"))
        XCTAssertEqual(Letterboxd.slug("https://letterboxd.com/someone/film/the-gift-2000/"), "the-gift-2000")
        XCTAssertTrue(Letterboxd().handles("https://boxd.it/2bnu"))
        XCTAssertFalse(Letterboxd().handles("https://letterboxd.com/films/popular/"))
    }
}

final class MetaTests: XCTestCase {
    func testWords() {
        XCTAssertEqual(Meta.words("  breaking   bad "), "breaking bad")
        XCTAssertEqual(Meta.words("breaking\tbad"), "breaking bad")
        XCTAssertEqual(Meta.words("breaking\u{00A0}bad"), "breaking bad")       // no-break space
        XCTAssertEqual(Meta.words("dune\u{2009}part\u{202F}two"), "dune part two")
        XCTAssertEqual(Meta.words("the\u{3000}office"), "the office")
        XCTAssertEqual(Meta.words("the\u{200B} office\u{FEFF}"), "the office")
    }

    func testSearchUrl() {
        XCTAssertEqual(Meta.searchUrl("series", " breaking  bad "), "https://v3-cinemeta.strem.io/catalog/series/top/search=breaking%20bad.json")
        XCTAssertEqual(Meta.searchUrl("movie", "schindler's list + 1"),
                       "https://v3-cinemeta.strem.io/catalog/movie/top/search=schindler%27s%20list%20%2B%201.json")
    }

    func testStremioAndNuvio() {
        let movie = Title(imdbId: "tt0120737", name: "The Fellowship of the Ring", series: false)
        XCTAssertEqual(movie.stremioLink(streams: true), "stremio:///detail/movie/tt0120737/tt0120737")
        let ep = Title(imdbId: "tt42127457", name: "Agent Kim's", series: true, season: 1, episode: 4)
        XCTAssertEqual(ep.stremioLink(streams: true), "stremio:///detail/series/tt42127457/tt42127457:1:4")
        XCTAssertEqual(
            TvLink.command(ep, component: "com.stremio.one/com.stremio.one.MainActivity", stremio: true),
            "am start -n 'com.stremio.one/com.stremio.one.MainActivity' -f 0x14000000 -a android.intent.action.VIEW -d 'stremio:///detail/series/tt42127457/tt42127457:1:4'"
        )
        XCTAssertTrue(TvLink.command(ep, component: "com.nuvio.tv/com.nuvio.tv.MainActivity").contains("--es name 'Agent Kim'\\''s'"))
    }

    func testUpdatesCompareByNumber() {
        XCTAssertTrue(Updates.newer("1.10.0", "1.9.2"))
        XCTAssertTrue(Updates.newer("2.0", "1.99.99"))
        XCTAssertFalse(Updates.newer("1.8.0", "1.8.0"))
        XCTAssertFalse(Updates.newer("1.8", "1.8.0"))
    }

    func testLinks() {
        XCTAssertEqual(Links.linkIn("Watch this: https://www.youtube.com/watch?v=x."), "https://www.youtube.com/watch?v=x")
        XCTAssertEqual(Links.site("https://www.hotstar.com/in/movies/x"), "hotstar.com")
        XCTAssertEqual(Links.fromSlug("https://www.hotstar.com/in/movies/maa-inti-bangaaram/1271716364"), "Maa Inti Bangaaram")
        XCTAssertEqual(Links.forTv("https://www.hotstar.com/in/movies/x/1"), "hotstar://in/movies/x/1")
        XCTAssertEqual(TvLink.components("com.nuvio.tv/.MainActivity\nActivity #0:"), ["com.nuvio.tv/com.nuvio.tv.MainActivity"])
    }
}

final class ProtocolTests: XCTestCase {
    private func hex(_ s: String) -> Data { Messages.hex(s) }

    /** A 2048-bit number: 2^2047 + n, big-endian. */
    private func big(_ n: UInt32) -> Data {
        var b = [UInt8](repeating: 0, count: 256)
        b[0] = 0x80
        b[252] = UInt8(n >> 24); b[253] = UInt8((n >> 16) & 0xFF); b[254] = UInt8((n >> 8) & 0xFF); b[255] = UInt8(n & 0xFF)
        return Data(b)
    }

    func testPairingSecretMatchesThePythonImplementation() {
        let client = Messages.RsaKey(modulus: big(123_456_789), exponent: Data([1, 0, 1]))
        let server = Messages.RsaKey(modulus: big(987_654_321), exponent: Data([1, 0, 1]))
        let expected = hex("598257ac4bf5247e2ac604016a290cd0b33a97646b6df08064d4360358ee4003")
        XCTAssertEqual(Messages.pairingSecret(client: client, server: server, code: "59ABCD"), expected)
        XCTAssertEqual(Messages.pairingSecret(client: client, server: server, code: "59abcd"), expected)
        XCTAssertNil(Messages.pairingSecret(client: client, server: server, code: "58ABCD"))
        XCTAssertNil(Messages.pairingSecret(client: client, server: server, code: "59ABC"))
    }

    func testMessageBytes() throws {
        XCTAssertEqual(Messages.keyInject(19), hex("520408131003"))
        XCTAssertEqual(Messages.keyInject(59, direction: Messages.directionDown), hex("5204083b1001"))
        XCTAssertEqual(Messages.appLink("x"), hex("d205030a0178"))
        XCTAssertEqual(Messages.pairingRequest("Skiff").prefix(5), hex("080210c801"))
        XCTAssertEqual(try Messages.Outer(Messages.pairingRequest("Skiff")).status, 200)
        XCTAssertEqual(ProtoWriter.frame(Messages.keyInject(23)), hex("06520408171003"))
    }

    func testReadsTheTvsMessages() throws {
        let inject = hex("a201350a270884021001188680801038004000620c636f6d2e6e7576696f2e747668ffffffffffffffffff01120a083c1200180020002801")
        let m = try Messages.Remote(inject)
        XCTAssertEqual(m.imeAppCounter, 260)
        XCTAssertEqual(m.imeFieldCounter, 60)
        let ping = ProtoWriter.build { $0.message(8) { $0.varint(1, 42) } }
        XCTAssertEqual(try Messages.Remote(ping).pingVal1, 42)
    }

    private func tempKey() throws -> SecKey {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        var error: Unmanaged<CFError>?
        return try XCTUnwrap(SecKeyCreateRandomKey(attrs as CFDictionary, &error))
    }

    /** The self-signed certificate is one iOS reads, with our key in it. */
    func testCertificateParses() throws {
        let key = try tempKey()
        let der = try Identity.selfSignedCertificate(key: key)
        let cert = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        XCTAssertEqual(SecCertificateCopySubjectSummary(cert) as String?, "Skiff")
        let pub = try XCTUnwrap(SecCertificateCopyKey(cert))
        XCTAssertEqual(SecKeyCopyExternalRepresentation(pub, nil) as Data?, try Identity.publicKeyData(key))
        XCTAssertNotNil(Identity.rsaNumbers(certificate: cert))
    }

    /** ADB's key format: 524 bytes; n0inv · n[0] ≡ −1 (mod 2³²). */
    func testAdbPublicKey() throws {
        let key = try tempKey()
        let pkcs1 = try Identity.publicKeyData(key)
        let data = try XCTUnwrap(Data(base64Encoded: try AdbKey.encode(pkcs1: pkcs1)))
        XCTAssertEqual(data.count, 524)
        func u32(_ i: Int) -> UInt32 { data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: i, as: UInt32.self)) } }
        XCTAssertEqual(u32(0), 64)
        XCTAssertEqual(u32(4) &* u32(8), UInt32.max)
        XCTAssertEqual(u32(520), 65537)
    }

    func testAdbMessage() {
        let m = Adb.Message(command: Adb.CNXN, arg0: 0x0100_0001, arg1: 4096, payload: Data("host::\0".utf8))
        let e = m.encoded()
        XCTAssertEqual(e.count, 24 + 7)
        XCTAssertEqual(e.prefix(4), Data("CNXN".utf8))
    }
}
