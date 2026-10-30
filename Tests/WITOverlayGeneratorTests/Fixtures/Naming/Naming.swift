struct NamingTestWorldExportsImpl: NamingTestWorldExports {
    static func roundtripRecord(v: KeywordingRecord) -> KeywordingRecord { v }
    static func roundtripEnum(v: KeywordingEnum) -> KeywordingEnum { v }
    static func roundtripVariant(v: KeywordingVariant) -> KeywordingVariant { v }
    static func roundtripFlags(v: KeywordingFlags) -> KeywordingFlags { v }
    static func `init`(`self`: Self_) -> Self_ { `self` }
    static func `class`(t: Type_, a: Any_, p: Protocol_) -> Protocol_ { p }
}
