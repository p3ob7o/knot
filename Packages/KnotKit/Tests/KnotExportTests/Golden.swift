/// The golden files of KnotExport: what the notes of `GoldenWorld` become. A change to the
/// Markdown that export writes changes these on purpose, in the same pull request.
enum Golden {
    /// N1 in an export with no drawing images: the drawing leaves as its stored data.
    static let n1Exported = """
        ---
        id: 019a9b3c-7e00-7000-8000-000000000001
        created: 2026-11-18T11:06:40Z
        updated: 2026-11-18T11:16:40Z
        ---

        # Roof, and stamps

        Call the roofer about the leak.
        Ask for Tuesday.

        Call the roofer about the leak on Tuesday.

        [Recording, 0:42](attachments/019a9b3c-7e00-7000-8000-0000000000a2.m4a)

        Buy stamps, and post the forms.

        [Drawing](attachments/019a9b3c-7e00-7000-8000-0000000000a3.drawing)

        call the vet at noon

        *Recording, 1:15: not on this device, not exported.*

        """

    /// N1 in an export given the drawing's image.
    static let n1ExportedWithImage = """
        ---
        id: 019a9b3c-7e00-7000-8000-000000000001
        created: 2026-11-18T11:06:40Z
        updated: 2026-11-18T11:16:40Z
        ---

        # Roof, and stamps

        Call the roofer about the leak.
        Ask for Tuesday.

        Call the roofer about the leak on Tuesday.

        [Recording, 0:42](attachments/019a9b3c-7e00-7000-8000-0000000000a2.m4a)

        Buy stamps, and post the forms.

        ![Drawing](attachments/019a9b3c-7e00-7000-8000-0000000000a3.png)

        call the vet at noon

        *Recording, 1:15: not on this device, not exported.*

        """

    /// N2, which has no title.
    static let n2Exported = """
        ---
        id: 019a9b3c-7e00-7000-8000-000000000002
        created: 2026-11-16T11:06:40Z
        updated: 2026-11-16T11:06:40Z
        ---

        Shopping: milk, eggs
        and bread

        """

    /// N1 shared or dragged out as Markdown by itself: no line for its files.
    static let n1Shared = """
        ---
        id: 019a9b3c-7e00-7000-8000-000000000001
        created: 2026-11-18T11:06:40Z
        updated: 2026-11-18T11:16:40Z
        ---

        # Roof, and stamps

        Call the roofer about the leak.
        Ask for Tuesday.

        Call the roofer about the leak on Tuesday.

        Buy stamps, and post the forms.

        call the vet at noon

        """

    /// N1 as plain text, as "Copy note" gives it.
    static let n1Text = """
        Roof, and stamps

        Call the roofer about the leak.
        Ask for Tuesday.

        Call the roofer about the leak on Tuesday.

        Buy stamps, and post the forms.

        call the vet at noon

        """

    static let n1File = "2026-11-18 Roof, and stamps 00000001.md"
    static let n2File = "2026-11-16 Shopping milk, eggs 00000002.md"
}
