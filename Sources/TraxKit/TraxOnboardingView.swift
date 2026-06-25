import SwiftUI

/// The front door: primes location permission with a plain-language "why" before
/// iOS's one-shot prompt, and offers a Settings path if the user denied. Shown by
/// TraxRootView until location is authorized (When-In-Use or Always).
struct TraxOnboardingView: View {
    let permissions: TraxPermissions

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Color.accentColor)
                Text("Trax").font(.largeTitle.bold())
                Text("See your people on a map, and share where you are — only with the friends you choose.")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            VStack(alignment: .leading, spacing: 16) {
                bullet("person.2.fill", "Your circle", "See friends and family who share with you, live.")
                bullet("mappin.and.ellipse", "Places", "Get a heads-up when they arrive at or leave a place.")
                bullet("battery.100", "Battery-smart", "Trax tracks tightly when you're moving, and backs off when you're still.")
            }
            .padding(.horizontal, 8)

            Spacer()

            VStack(spacing: 10) {
                if permissions.isDenied {
                    Text("Trax needs location access to work. Turn it on in Settings — choose \u{201C}Always\u{201D} so sharing keeps working in the background.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { permissions.openSettings() } label: {
                        Text("Open Settings").bold().frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("We'll ask for location and motion next. Share your spot with the friends you choose — or deny and just watch the people who share with you.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button { permissions.requestPermissions() } label: {
                        Text("Set Permissions").bold().frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(28)
    }

    private func bullet(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
