/// The golden files of `CaptureManifest` (docs/architecture.md §3): one set, which every
/// test that reads or writes a manifest compares against, so the recorder, the watch outbox
/// and ingest cannot drift apart. A change to the format adds a new golden file and keeps
/// the old ones, which every later build must still read.
public enum CaptureManifestGolden {
    /// Format 1: a watch recording, every field present.
    public static let formatOne = #"""
        {"capture_id":"019a9b3c-7e00-7000-8000-000000000001","duration_seconds":42.5,"ended_at":"2026-11-18T11:07:22.500Z","format":1,"kind":"voice","launch_id":"019a9b3c-7e00-7000-8000-000000000002","payload_bytes":21000,"payload_sha256":"abababababababababababababababababababababababababababababababab","placement":"window","revision":3,"shown_note_id":"019a9b3c-7e00-7000-8000-000000000003","source":"device:019a9b3c-7e00-7000-8000-000000000004","started_at":"2026-11-18T11:06:40.000Z","surface":"watch"}
        """#

    /// Format 1 as a newer Knot might write it: a kind and a surface this build does not know,
    /// which it keeps, and two fields it does not know, which it reads past.
    public static let formatOneWithUnknownFields = #"""
        {"capture_id":"019a9b3c-7e00-7000-8000-000000000001","format":1,"kind":"photo","launch_id":"019a9b3c-7e00-7000-8000-000000000002","lens":{"focal_mm":24,"front":false},"placement":"new_note","revision":0,"source":"cli","started_at":"2026-11-18T11:06:40.000Z","surface":"car_play","tags":["x",null]}
        """#

    /// Format 1 with `follows_capture_id`: a recording begun by holding the Mac hotkey while
    /// typing, which ended the typed capture it names.
    public static let formatOneFollowingACapture = #"""
        {"capture_id":"019a9b3c-7e00-7000-8000-000000000001","duration_seconds":12.25,"ended_at":"2026-11-18T11:06:52.250Z","follows_capture_id":"019a9b3c-7e00-7000-8000-000000000005","format":1,"kind":"voice","launch_id":"019a9b3c-7e00-7000-8000-000000000002","payload_bytes":9000,"payload_sha256":"cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd","placement":"window","revision":0,"shown_note_id":"019a9b3c-7e00-7000-8000-000000000003","source":"device:019a9b3c-7e00-7000-8000-000000000004","started_at":"2026-11-18T11:06:40.000Z","surface":"mac_panel"}
        """#

    /// Format 1 with `last_saved_at`: a typed draft a crash left open, and when it was last
    /// saved.
    public static let formatOneWithTheLastSave = #"""
        {"capture_id":"019a9b3c-7e00-7000-8000-000000000001","format":1,"kind":"typed","last_saved_at":"2026-11-18T11:07:11.125Z","launch_id":"019a9b3c-7e00-7000-8000-000000000002","placement":"window","revision":7,"shown_note_id":"019a9b3c-7e00-7000-8000-000000000003","source":"device:019a9b3c-7e00-7000-8000-000000000004","started_at":"2026-11-18T11:06:40.000Z","surface":"app"}
        """#
}
