import SwiftUI

/// "What am I hearing?": the phrases and words that come up most on a tower frequency.
struct GlossaryView: View {
    struct Term: Identifiable {
        let phrase: String
        let meaning: String
        var id: String { phrase }
    }

    struct TermGroup: Identifiable {
        let title: String
        let terms: [Term]
        var id: String { title }
    }

    static let groups: [TermGroup] = [
        TermGroup(title: "Who's who", terms: [
            Term(phrase: "Delivery / Clearance", meaning: "Reads each flight its route before it leaves the gate."),
            Term(phrase: "Ground", meaning: "Runs the taxiways: gate to runway and back."),
            Term(phrase: "Tower", meaning: "Owns the runways: every takeoff and landing, and the air a few miles around."),
            Term(phrase: "Departure / Approach", meaning: "Radar controllers out to about 40-60 nm, climbing flights out and lining arrivals up."),
            Term(phrase: "Center", meaning: "High-altitude traffic between airports."),
            Term(phrase: "ATIS / Information Kilo", meaning: "The recorded airport report. Pilots say \"with Kilo\" to show they've heard the current one."),
        ]),
        TermGroup(title: "On the runway", terms: [
            Term(phrase: "Cleared for takeoff", meaning: "The runway is theirs; go."),
            Term(phrase: "Line up and wait", meaning: "Taxi onto the runway and hold there, ready to go."),
            Term(phrase: "Hold short", meaning: "Stop before the runway; don't cross it."),
            Term(phrase: "Cleared to land", meaning: "The runway is clear for this arrival."),
            Term(phrase: "Go around", meaning: "Abandon the landing, climb, and come back around. Routine and safe."),
            Term(phrase: "Runway 22 Left", meaning: "Runways are named by compass heading divided by 10: 22 = about 220°. Left and right tell parallels apart."),
        ]),
        TermGroup(title: "In the air", terms: [
            Term(phrase: "Climb and maintain 5,000", meaning: "Climb to 5,000 ft and stay there."),
            Term(phrase: "Turn left heading 270", meaning: "Fly toward 270° (west) until told otherwise."),
            Term(phrase: "Descend via the arrival", meaning: "Follow the published descent procedure for this airport."),
            Term(phrase: "Contact departure 133.0", meaning: "Switch radios to the next controller on 133.0 MHz."),
            Term(phrase: "Traffic, 2 o'clock, 5 miles", meaning: "Another plane is ahead and to the right, 5 nm away. 12 o'clock = straight ahead."),
            Term(phrase: "Flight level 350", meaning: "35,000 ft (on the standard altimeter setting, used up high)."),
        ]),
        TermGroup(title: "Words you'll hear", terms: [
            Term(phrase: "Roger / Wilco", meaning: "Heard it / will comply."),
            Term(phrase: "Say again", meaning: "Repeat that."),
            Term(phrase: "Squawk 4521", meaning: "Set the transponder to code 4521 so radar can tell the plane apart."),
            Term(phrase: "Squawk 7700 / 7600 / 7500", meaning: "Emergency / lost radio / hijack. Skyfi shows these in red."),
            Term(phrase: "Heavy / Super", meaning: "Added to big jets' callsigns (\"Delta 12 Heavy\") because of their wake turbulence."),
            Term(phrase: "Niner, tree, fife", meaning: "Radio ways of saying 9, 3 and 5 so they aren't misheard."),
            Term(phrase: "Speedbird, Cactus, Springbok", meaning: "Airline callsigns: British Airways, American (from America West), South African."),
        ]),
    ]

    var body: some View {
        List {
            ForEach(Self.groups) { group in
                Section(group.title) {
                    ForEach(group.terms) { term in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(term.phrase).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.cyan)
                            Text(term.meaning).font(.system(size: 13)).foregroundStyle(Theme.text)
                        }
                        .padding(.vertical, 2)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .navigationTitle("What am I hearing?")
        .navigationBarTitleDisplayMode(.inline)
    }
}
