//
//  CreatedByView.swift
//  Raul
//
//  Created by Holger Krupp on 22.08.25.
//

import SwiftUI

struct CreatedByView: View {
    private let websiteURL = URL(string: "https://rogerpincombe.com")!
    private let sourceCodeURL = URL(string: "https://github.com/OkGoDoIt/Moves")!
    private let originalAppURL = URL(string: "https://extremelysuccessfulapps.com/moves/")!
    private let cityDataURL = URL(string: "https://www.geonames.org")!

    var body: some View {
        VStack(spacing: 0) {
            Text("This version by")

            Link(destination: websiteURL) {
                Label {
                    Text(verbatim: "Roger Pincombe")
                } icon: {
                    Image(systemName: "globe")
                }
                .creditLink()
            }

            Link(destination: sourceCodeURL) {
                Label("Get the source code", image: "githublogo")
                    .creditLink()
            }

            VersionNumberView()
                .font(.caption)
                .padding(.top, 2)

            Divider()
                .padding(.vertical, 14)

            Text("Based on the original Moves by")

            Link(destination: originalAppURL) {
                Label {
                    Text(verbatim: "Extremely Successful Apps")
                } icon: {
                    Image("extremelysuccessfullogo")
                }
                .creditLink()
            }

            Divider()
                .padding(.vertical, 14)

            Link(destination: cityDataURL) {
                Text("City names from GeoNames, CC BY 4.0")
                    .font(.caption)
                    .creditLink()
            }
        }
        .multilineTextAlignment(.center)
        .padding(.top, 4)
    }
}

private extension View {
    /// Keeps each credit at a full-size touch target.
    func creditLink() -> some View {
        foregroundStyle(.accent)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct CreatedByView_Previews: PreviewProvider {
    static var previews: some View {
        CreatedByView()
    }
}
