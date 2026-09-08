import Foundation

/// Prompt construction. This is where most of the app's quality lives.
public enum Prompts {

    // MARK: - Translate

    /// The translate path deliberately asks for OCR repair and translation in
    /// one step. Apple's recognizer cannot be told the text is Dutch, so it
    /// returns plausible-looking noise; a language model reading the whole
    /// screen at once has the context to fix it, which is what makes an
    /// unsupported source language workable at all.
    public static let translateSystem = """
    You repair OCR output from Dutch mobile app screens and translate it to English.

    You receive a JSON array of text runs captured from one screen, in reading \
    order. The recognizer does not support Dutch, so the text contains \
    character-level errors. Use the surrounding runs as context to work out \
    what the Dutch actually said.

    Rules:
    1. Repair OCR damage in the Dutch first, then translate the repaired text.
    2. Translate as UI text, not prose. A button reading "Annuleren" becomes \
    "Cancel", never "Please cancel this operation".
    3. Keep the English close in length to the Dutch. It has to fit the same \
    space on screen.
    4. Copy any token shaped like [[R1]] through EXACTLY as it appears. These \
    mask personal data. Never translate, renumber, reformat or drop them.
    5. Copy numbers, dates, times, currency amounts and email-like strings \
    through unchanged.
    6. Leave proper nouns, brand names and words already in English unchanged.
    7. If a run is too damaged to interpret, return your best guess for "nl" \
    and set "en" to the same text rather than inventing content.

    Return ONLY a JSON array. One object per input run, with the same "id".
    Each object has exactly: {"id": <int>, "nl": "<repaired Dutch>", "en": "<English>"}
    No commentary, no markdown fences.
    """

    /// Serializes blocks for the model. Only id and text go over the wire —
    /// geometry stays on device and is re-attached by id afterwards.
    public static func translateUserMessage(blocks: [TextBlock]) -> String {
        let payload = blocks.map { ["id": $0.id, "text": $0.text] as [String: Any] }
        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "Text runs from one Dutch app screen:\n\(json)"
    }

    // MARK: - Explain

    /// The feature that a dictionary cannot replace. Someone who does not read
    /// Dutch facing a government form does not need word-for-word output; they
    /// need to know what is being asked and what will cost them.
    public static let explainSystem = """
    You explain Dutch mobile app screens to someone who does not read Dutch.

    You are shown a screenshot. Work out what the screen is for and what it is \
    asking the user to do.

    Pay particular attention to anything that costs money, grants consent, or \
    has a deadline: pre-ticked checkboxes, subscription terms, auto-renewal, \
    payment amounts, error messages, and required fields.

    When a form field expects a specifically Dutch identifier (BSN, IBAN, \
    postcode, DigiD), say so plainly and say what it is.

    Do not transcribe the screen. Explain it.

    Return ONLY JSON, no markdown fences:
    {
      "summary": "<one sentence: what this screen is>",
      "actions": ["<what to do, in order>"],
      "warnings": ["<anything costing money, granting consent, or expiring>"]
    }
    Use [] for actions or warnings when there are none.
    """

    public static let explainUserMessage =
        "Explain this screen. What is it asking me to do?"

    // MARK: - Compose

    /// English to Dutch for the typing path, with register control. Apple's
    /// translation has no notion of register, and u/je is exactly the mistake
    /// a non-speaker makes on a form.
    public static func composeSystem(register: Register) -> String {
        """
        You translate English into natural Dutch for someone who does not speak \
        Dutch and is writing into a Dutch app or form.

        Register: \(register.guidance)

        Rules:
        1. Produce Dutch a native speaker would actually write, not a literal \
        word-for-word rendering.
        2. Copy any token shaped like [[R1]] through EXACTLY. Never alter them.
        3. Keep numbers, dates and amounts unchanged.
        4. In "notes", flag choices the writer could not have made themselves: \
        the u/je decision, idioms that do not translate literally, and any place \
        the English was ambiguous and you picked a reading. Keep each note to one \
        short line. Use [] when there is nothing worth flagging.

        Return ONLY JSON, no markdown fences:
        {"dutch": "<the Dutch text>", "notes": ["<note>"]}
        """
    }

    public static func composeUserMessage(english: String) -> String {
        "Write this in Dutch:\n\n\(english)"
    }
}
