// SPDX-FileCopyrightText: 2026 Chuli (GitHub: chuli1122) <https://github.com/chuli1122/Tincall>
// SPDX-License-Identifier: LicenseRef-Tincall-Personal-Use

import SwiftUI

struct CallGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.glassEffect(.regular,
                            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct CallControlSurface: ViewModifier {
    let tint: Color?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            // Glass tint can disappear in the system's inactive app snapshot.
            .background(scenePhase == .active ? .clear : (tint ?? .clear), in: Circle())
            .glassEffect(.regular.tint(tint).interactive(), in: Circle())
    }
}

struct CallRoundButton: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    @Environment(\.callPalette) private var palette

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(palette.primaryText)
                    .frame(width: 68, height: 68)
                    .modifier(CallControlSurface(tint: CallNight.lavender))
                Text(title)
                    .font(CallNight.font(11))
                    .foregroundStyle(palette.secondaryText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
