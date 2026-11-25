import Foundation

/// The benchmark's vocabulary and sentences. Everything here is invented: no name, company or
/// sentence comes from a real meeting. The filler follows the AMI corpus's scenario (a team
/// designing a remote control), which is what Parley's other fixtures use.
enum Corpus {
    enum Category: String, CaseIterable, Codable {
        /// Names an ASR model rarely spells right: the case the feature exists for.
        case distinctiveName = "distinctive name"
        /// First name + surname as one term.
        case fullName = "full name"
        /// Names that are also ordinary English words: what a calendar seed brings in.
        case ordinaryWordName = "ordinary-word name"
        /// Short names and brands that sound like ordinary words.
        case shortColliding = "short, colliding"
        case product = "product / company"
        case jargon = "jargon"
    }

    struct Term {
        let text: String
        let category: Category
    }

    static let terms: [Term] = [
        // 16 distinctive names
        "Saoirse", "Siobhan", "Joaquin", "Thibault", "Katarzyna", "Nguyen", "Oluwaseun", "Anneke",
        "Priyanka", "Matthias", "Xiomara", "Callum", "Imogen", "Dmitri", "Okonkwo", "Szymanski",
    ].map { Term(text: $0, category: .distinctiveName) }
        + ["Lars Eriksen", "Priya Raman"].map { Term(text: $0, category: .fullName) }
        + ["Will", "Grace", "Mark", "Rose", "Bill", "Frank", "Hunter", "Chase"]
            .map { Term(text: $0, category: .ordinaryWordName) }
        + ["Snyk", "CRAN", "Kaia", "Lior", "Jira", "Wren", "Mira", "Arlo", "Nils", "Ines"]
            .map { Term(text: $0, category: .shortColliding) }
        + [
            "Kubernetes", "Grafana", "Databricks", "Snowflake", "PostgreSQL", "Terraform", "Figma",
            "Datadog", "Supabase", "Vercel", "Zendesk", "HubSpot",
        ].map { Term(text: $0, category: .product) }
        + ["EBITDA", "idempotent", "Kanban", "OAuth"].map { Term(text: $0, category: .jargon) }

    /// `{T}` is the term. Three carriers per term, taken in rotation.
    static let nameCarriers = [
        "Okay, so {T} is going to present the prototype after lunch.",
        "I talked to {T} yesterday about the budget for the remote control.",
        "Um, I think {T} already sent the minutes to everyone.",
        "Yeah, can you ask {T} to check the battery costs?",
        "Right, {T} and I looked at the user survey this morning.",
        "So the action item for {T} is the industrial design report.",
    ]
    static let productCarriers = [
        "We moved the whole thing over to {T} last quarter.",
        "Um, does anyone here actually know how {T} works?",
        "So the plan is to use {T} for the next release.",
        "I mean, {T} was fine until the last update.",
        "Okay, let's look at the numbers in {T} before we decide.",
        "Yeah, the team is still learning {T}, so it will take a while.",
    ]
    static let jargonCarriers = [
        "The {T} question came up again in the review.",
        "I'm not sure the {T} part is finished yet.",
        "Let's put {T} on the agenda for next week.",
    ]

    static func carriers(for category: Category) -> [String] {
        switch category {
        case .distinctiveName, .fullName, .ordinaryWordName: return nameCarriers
        case .shortColliding, .product: return productCarriers
        case .jargon: return jargonCarriers
        }
    }

    /// Ordinary meeting talk with no vocabulary term in it.
    static let filler = [
        "Okay, so I think we should start with the remote control design.",
        "Um, yeah, I mean the buttons could be made of rubber.",
        "So the first thing on the agenda is the project plan.",
        "I was thinking we could have a scroll wheel on the side.",
        "Right, and the budget is twelve and a half euros per unit.",
        "Do we want it to work with the television and the video player?",
        "Yeah, I guess the younger market wants something fashionable.",
        "Well, the batteries are going to be the most expensive part.",
        "Could you put the slides up on the screen, please?",
        "I'm not sure we have enough time to go through all of this.",
        "So what did the marketing survey actually say about the colours?",
        "Okay, that's a good point, let's write that down.",
        "We need to decide on the casing before the next meeting.",
        "Um, I think a curved shape would feel better in the hand.",
        "The users said they lose the remote all the time.",
        "So maybe it should make a noise when you whistle or clap.",
        "That would add about two euros to the production cost.",
        "Right, so who is going to take the minutes today?",
        "I think speech recognition is a bit too ambitious for this price.",
        "Let's move on to the next item, which is the user interface.",
        "Yeah, the volume and the channel buttons should be the biggest.",
        "Okay, I'll send everybody an email with the action points.",
        "Is everyone happy with that, or should we discuss it again?",
        "We have about five minutes left, so let's wrap up.",
        "I mean, the screen would be nice, but it uses a lot of power.",
        "So the kinetic charger means you never have to change batteries.",
        "Thanks everyone, that was a really useful discussion.",
        "Um, sorry, could you go back to the previous slide?",
        "The company wants the logo to be visible on the front.",
        "All right, so we agree on the yellow case with black buttons.",
    ]

    /// Ordinary talk built to sound like a term without containing one: the words a wrong
    /// substitution would land on. (A sentence that contains a term's own spelling as an ordinary
    /// word, "the costs rose", is here on purpose: only the capital letter can change.)
    static let hardNegatives = [
        "We need to sync the two calendars before Friday.",                  // Snyk
        "She ran the numbers again last night.",                             // CRAN
        "I think the crane will arrive on Thursday.",                        // CRAN
        "The price is higher than we expected.",                             // Kaia
        "Our lawyer said the contract is fine.",                             // Lior
        "The gear a team needs depends on the project.",                     // Jira
        "When are we going to ship the first version?",                      // Wren
        "There is a mirror on the wall behind you.",                         // Mira
        "That is a low estimate, I think.",                                  // Arlo
        "He kneels down to plug in the cable.",                              // Nils
        "In his opinion the design is too heavy.",                           // Ines
        "Well, I will do it tomorrow if nobody else will.",                  // Will
        "The grays and the blues look good together.",                       // Grace
        "Mark my words, the market is going to change.",                     // Mark
        "The costs rose by ten percent, and the rows in the table show it.", // Rose
        "Please send the bill to the building manager.",                     // Bill
        "To be frank, I think we should think again.",                       // Frank
        "They hired a head hunter to find the new designer.",                // Hunter
        "Could you chase the supplier, in any case?",                        // Chase
        "It was a sheer waste of time, to be honest.",                       // Saoirse
        "She shoved on the door and it opened.",                             // Siobhan
        "You can walk in whenever you like.",                                // Joaquin
        "We should tip the board over and look underneath.",                 // Thibault
        "I hope we win when the results come out.",                          // Nguyen
        "There was an echo on the line this morning.",                       // Anneke
        "My tires need changing before the winter.",                         // Matthias
        "Put the totals in the last column.",                                // Callum
        "Imagine the remote without any buttons at all.",                    // Imogen
        "The meter on the wall shows the temperature.",                      // Dmitri
        "The coupon gets you ten percent off the price.",                    // Kubernetes
        "We stored the data in bricks of a thousand rows.",                  // Databricks
        "A few snow flakes were falling when I came in.",                    // Snowflake
        "The post has grown a lot since we wrote it.",                       // PostgreSQL
        "The terrace forms a nice space for lunch.",                         // Terraform
        "It is a figment of your imagination.",                              // Figma
        "The data dog ate my homework, as they say.",                        // Datadog
        "The super base model costs a little more.",                         // Supabase
        "The hub and spoke layout works for the warehouse.",                 // HubSpot
        "He can bend the plastic with a heat gun.",                          // Kanban
        "Oh, both of them are out of the office today.",                     // OAuth
    ]

    static let voices = ["Samantha", "Daniel", "Karen", "Moira", "Rishi"]

    enum Kind: String, Codable {
        case positive, filler, hardNegative
    }

    struct Utterance: Codable {
        let id: String
        let kind: Kind
        let voice: String
        let text: String
        /// The term spoken in a positive utterance.
        let term: String?
        let category: Category?
    }

    static func utterances() -> [Utterance] {
        var result: [Utterance] = []
        for voice in voices {
            for (index, term) in terms.enumerated() {
                let carriers = carriers(for: term.category)
                for round in 0..<3 {
                    let carrier = carriers[(index + round * 2) % carriers.count]
                    result.append(
                        Utterance(
                            id: "pos-\(voice)-\(index)-\(round)", kind: .positive, voice: voice,
                            text: carrier.replacingOccurrences(of: "{T}", with: term.text),
                            term: term.text, category: term.category))
                }
            }
            for (index, text) in filler.enumerated() {
                result.append(
                    Utterance(
                        id: "fil-\(voice)-\(index)", kind: .filler, voice: voice, text: text, term: nil,
                        category: nil))
            }
            for (index, text) in hardNegatives.enumerated() {
                result.append(
                    Utterance(
                        id: "neg-\(voice)-\(index)", kind: .hardNegative, voice: voice, text: text, term: nil,
                        category: nil))
            }
        }
        return result
    }
}
