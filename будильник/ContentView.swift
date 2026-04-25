// ContentView.swift
import SwiftUI
import Combine
import UniformTypeIdentifiers
import UIKit
import UserNotifications

/// Крупные числа: шаги, активные ккал, сон — на главном экране и в Health services.
private struct HealthMetricTilesBlock: View {
    let summary: DayHealthSummary?
    var isStaleCached: Bool = false
    /// Сервер отдал демо/заглушку — цифры не из Huawei Health на телефоне.
    var isDemoSample: Bool = false
    /// См. `DayHealthSummary.stepsAndEnergyAreNightExtendedSlice` (можно задать явно для Huawei, где флага нет).
    var useExtendedActivitySlice: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Шаги · калории · сон")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
                if isStaleCached {
                    Text("кэш")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.22)))
                }
                if isDemoSample {
                    Text("демо")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.yellow.opacity(0.18)))
                }
            }
            if isDemoSample {
                Text("Эти числа приходят с вашего backend в демо-режиме (MOCK), а не из приложения Huawei Health. Чтобы совпадали с часами/телефоном, на Render выключите MOCK_MODE и подключите реальный источник данных Huawei.")
                    .font(.caption2)
                    .foregroundStyle(Color.yellow.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 8) {
                metricTile(
                    title: "Шаги",
                    value: stepsText,
                    footnote: useExtendedActivitySlice ? "вчера+сегодня" : "за день",
                    icon: "figure.walk",
                    accent: .cyan
                )
                metricTile(
                    title: "Ккал",
                    value: kcalText,
                    footnote: useExtendedActivitySlice ? "вчера+сегодня" : "активные",
                    icon: "flame.fill",
                    accent: .orange
                )
                metricTile(
                    title: "Сон",
                    value: sleepText,
                    footnote: "прошлая ночь",
                    icon: "moon.zzz.fill",
                    accent: .indigo
                )
            }
        }
    }

    private var stepsText: String {
        guard let s = summary?.stepsToday else { return "—" }
        return s.formatted(.number.grouping(.automatic))
    }

    private var kcalText: String {
        guard let k = summary?.activeEnergyKcal else { return "—" }
        if k < 1 { return "—" }
        return "\(Int(k.rounded()))"
    }

    private var sleepText: String {
        guard let h = summary?.sleepLastNightHours else { return "—" }
        let t = (h * 10).rounded() / 10
        if t == floor(t) {
            return "\(Int(t)) ч"
        }
        return String(format: "%.1f ч", t)
    }

    private func metricTile(title: String, value: String, footnote: String, icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(accent.opacity(0.95))
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct ContentView: View {
    @StateObject private var alarmVM = AlarmViewModel()
    @StateObject private var sleepVM = SleepViewModel()
    @StateObject private var musicAlarmManager = AppleMusicAlarmManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("app.userRegistered") private var isUserRegistered = false
    @AppStorage("app.userPaid") private var isUserPaid = false
    @State private var showRegistrationLanding = false
    @State private var showPaywall = false

    @State private var showSoundStep = false
    @State private var showSleepMode = false
    @State private var showStats = false
    @State private var showWakeResult = false

    var body: some View {
        NavigationStack {
            AlarmSetupStepView(
                alarmVM: alarmVM,
                musicAlarmManager: musicAlarmManager,
                onNext: { showSoundStep = true },
                onOpenStats: { showStats = true },
                onSignOut: {
                    let d = UserDefaults.standard
                    d.removeObject(forKey: "app.userID")
                    d.removeObject(forKey: "app.userEmail")
                    d.removeObject(forKey: "app.userFullName")
                    d.removeObject(forKey: "app.userPaid")
                    isUserRegistered = false
                    showRegistrationLanding = true
                }
            )
            .navigationDestination(isPresented: $showSoundStep) {
                SoundSetupStepView(sleepVM: sleepVM, alarmVM: alarmVM, isEditingActiveSleepSession: false) {
                    showSleepMode = true
                }
            }
            .navigationDestination(isPresented: $showSleepMode) {
                SleepModeStepView(sleepVM: sleepVM, alarmVM: alarmVM) {
                    showSleepMode = false
                }
            }
            .navigationDestination(isPresented: $showStats) {
                StatsStepView(sleepVM: sleepVM)
            }
            .navigationTitle("Smart Alarm")
            .preferredColorScheme(.dark)
            .task {
                await alarmVM.requestNotificationPermissionIfNeeded()
            }
            .onChange(of: sleepVM.lastSession != nil) { _, hasSession in
                showWakeResult = hasSession
            }
            .sheet(isPresented: $showWakeResult) {
                if let session = sleepVM.lastSession {
                    WakeResultView(
                        session: session,
                        onContinue: {
                            sleepVM.markAsWokeUp()
                            showWakeResult = false
                        },
                        onOpenStats: {
                            sleepVM.markAsWokeUp()
                            showWakeResult = false
                            showStats = true
                        }
                    )
                }
            }
            .onAppear {
                sleepVM.syncSleepUIWhenViewAppears()
                if !isUserRegistered {
                    showRegistrationLanding = true
                } else {
                    Task { await refreshPaidStateFromSupabase() }
                }
            }
            .task(id: sleepVM.isRunning) {
                guard sleepVM.isRunning else { return }
                showSoundStep = true
                showSleepMode = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                sleepVM.syncSleepUIWhenViewAppears()
                Task {
                    await reconcileDeliveredWakeNotifications(sleepVM: sleepVM, alarmVM: alarmVM)
                    if isUserRegistered { await refreshPaidStateFromSupabase() }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                sleepVM.handleScenePhaseChange(phase)
            }
            .onReceive(NotificationCenter.default.publisher(for: .smartAlarmDidFire)) { note in
                let fireDate = note.userInfo?[Notification.Name.smartAlarmFireDateUserInfoKey] as? Date ?? Date()
                AlarmPlaybackAnchor.recordIfNeeded(fireDate)
                if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
                    sleepVM.handleExternalAlarmFired()
                } else if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
                    sleepVM.reassertAlarmPlaybackFromForegroundIfNeeded()
                } else if !sleepVM.isRunning {
                    alarmVM.playAlarmFromNotification(notificationDeliveryDate: fireDate)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .userDismissedMorningAlarm)) { _ in
                alarmVM.syncMorningAlarmDismissedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .sleepTimerDidEnd)) { _ in
                // Конец таймера сна: только остановка sleep-сессии, не запуск утреннего будильника.
                if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
                    sleepVM.stopSleep()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .alarmRemoteStopRequested)) { _ in
                if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
                    sleepVM.dismissAlarmAndFinish()
                } else {
                    alarmVM.stopAlarmRingingFromNotification()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
                alarmVM.handleSignificantTimeChange()
            }
            .onReceive(NotificationCenter.default.publisher(for: .paymentReturnFromWeb)) { note in
                guard let url = note.object as? URL else { return }
                Task { await handlePaymentReturnURL(url) }
            }
            .fullScreenCover(isPresented: $showRegistrationLanding) {
                AlarmRegistrationLandingView { payload in
                    let defaults = UserDefaults.standard
                    let storedID = defaults.string(forKey: "app.userID").flatMap(UUID.init(uuidString:))
                    let userID = storedID ?? UUID()
                    defaults.set(userID.uuidString.lowercased(), forKey: "app.userID")
                    defaults.set(payload.email, forKey: "app.userEmail")
                    defaults.set(payload.fullName, forKey: "app.userFullName")
                    if !payload.endpointURL.isEmpty {
                        defaults.set(payload.endpointURL, forKey: "dayHealth.huaweiAuto.endpoint")
                    }
                    if !payload.accessToken.isEmpty {
                        defaults.set(payload.accessToken, forKey: "dayHealth.huaweiAuto.token")
                    }
                    Task {
                        await SupabaseDirectRegistration.syncUserAfterSignup(
                            email: payload.email,
                            fullName: payload.fullName
                        )
                        let profile = await SupabaseProfiles.loadOrCreateProfile(
                            userID: userID,
                            email: payload.email
                        )
                        if let profile {
                            defaults.set(profile.paid, forKey: "app.userPaid")
                        }
                    }
                    isUserRegistered = true
                    isUserPaid = false
                    showPaywall = true
                    showRegistrationLanding = false
                }
                .interactiveDismissDisabled(true)
            }
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(
                    onPayTap: {
                        await openPaymentSuccessPage()
                    },
                    onRefresh: {
                        await refreshPaidStateFromSupabase()
                        if isUserPaid {
                            showPaywall = false
                        }
                })
                .interactiveDismissDisabled(true)
                .task {
                    await refreshPaidStateFromSupabase()
                }
            }
        }
    }

    @MainActor
    private func refreshPaidStateFromSupabase() async {
        let d = UserDefaults.standard
        guard isUserRegistered else {
            showPaywall = false
            return
        }
        guard let email = d.string(forKey: "app.userEmail")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else {
            isUserPaid = false
            showPaywall = true
            return
        }
        let storedID = d.string(forKey: "app.userID").flatMap(UUID.init(uuidString:))
        let userID = storedID ?? UUID()
        if storedID == nil {
            d.set(userID.uuidString.lowercased(), forKey: "app.userID")
        }
        if let profile = await SupabaseProfiles.loadOrCreateProfile(userID: userID, email: email) {
            isUserPaid = profile.paid
            showPaywall = !profile.paid
        } else {
            // Если сеть/база недоступны — остаёмся в безопасном состоянии с paywall.
            isUserPaid = false
            showPaywall = true
        }
    }

    @MainActor
    private func openPaymentSuccessPage() async {
        var normalized = AppCloudConfig.resolvedServiceRootURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://"), !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        guard var comp = URLComponents(string: normalized) else { return }
        comp.path = "/success"
        comp.queryItems = [
            URLQueryItem(name: "return_to", value: "smartalarm://payment-success?status=paid"),
        ]
        comp.fragment = nil
        guard let url = comp.url else { return }
        _ = await UIApplication.shared.open(url)
    }

    @MainActor
    private func handlePaymentReturnURL(_ url: URL) async {
        guard url.scheme?.lowercased() == "smartalarm" else { return }
        let host = url.host?.lowercased() ?? ""
        guard host == "payment-success" else { return }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let status = comps?.queryItems?.first(where: { $0.name == "status" })?.value?.lowercased()
        guard status == "paid" else { return }
        await markCurrentUserAsPaidForMVP()
        await refreshPaidStateFromSupabase()
        if isUserPaid {
            showPaywall = false
        }
    }

    @MainActor
    private func markCurrentUserAsPaidForMVP() async {
        let d = UserDefaults.standard
        guard let email = d.string(forKey: "app.userEmail")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return }
        let storedID = d.string(forKey: "app.userID").flatMap(UUID.init(uuidString:))
        let userID = storedID ?? UUID()
        if storedID == nil {
            d.set(userID.uuidString.lowercased(), forKey: "app.userID")
        }
        if let profile = await SupabaseProfiles.setPaidTrue(userID: userID, email: email) {
            isUserPaid = profile.paid
            showPaywall = !profile.paid
            d.set(profile.paid, forKey: "app.userPaid")
        }
    }
}

private struct AlarmRegistrationPayload {
    let fullName: String
    let email: String
    let endpointURL: String
    let accessToken: String
}

private struct AlarmRegistrationLandingView: View {
    let onRegistered: (AlarmRegistrationPayload) -> Void

    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isSubmitting = false
    @State private var errorMessage = ""

    /// Адрес сервера только из кода / Info.plist — пользователь ничего не вставляет.
    private var serverRoot: String { AppCloudConfig.resolvedServiceRootURL }

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.indigo.opacity(0.55), Color.purple.opacity(0.35)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 56, height: 56)
                                Image(systemName: "alarm.fill")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(.white)
                            }
                            Text("Smart Alarm")
                                .font(.largeTitle.weight(.bold))
                                .foregroundStyle(.white)
                            Text("Создайте аккаунт — имя, почта и пароль. Данные сохраняются на нашем сервере автоматически.")
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.72))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 8)

                        GlassCard {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Регистрация")
                                    .font(.headline)
                                TextField("Имя", text: $fullName)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                                    .foregroundStyle(.white)
                                    .textInputAutocapitalization(.words)

                                TextField("Email", text: $email)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                                    .foregroundStyle(.white)
                                    .keyboardType(.emailAddress)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                SecureField("Пароль (не меньше 6 символов)", text: $password)
                                    .textFieldStyle(.plain)
                                    .padding(12)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
                                    .foregroundStyle(.white)
                            }
                        }

                        if serverRoot.isEmpty {
                            Text("Регистрация сейчас недоступна. Установите обновление приложения или обратитесь в поддержку.")
                                .font(.caption)
                                .foregroundStyle(Color.orange.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !errorMessage.isEmpty {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(Color.orange.opacity(0.95))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        PrimaryGradientButton(title: isSubmitting ? "Отправка…" : "Создать аккаунт", systemImage: "person.badge.plus") {
                            Task { await submit() }
                        }
                        .disabled(isSubmitting || !canSubmit)
                        .opacity(canSubmit && !isSubmitting ? 1 : 0.55)

                        Text("Регистрируясь, вы соглашаетесь на обработку имени и email для работы аккаунта.")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("Добро пожаловать")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var canSubmit: Bool {
        isValidEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
            && password.count >= 6
            && !serverRoot.isEmpty
    }

    private func isValidEmail(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), let at = trimmed.firstIndex(of: "@") else { return false }
        let domain = trimmed[trimmed.index(after: at)...]
        return domain.contains(".") && trimmed.count >= 5
    }

    /// Как в `DayHealthInsightsStore`: домен → `https://…/v1/huawei/summary` для дальнейшего health-синка.
    private func normalizedHuaweiEndpointString(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        var s = trimmed
        if !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        guard var comp = URLComponents(string: s) else { return trimmed }
        let path = comp.path
        if path.isEmpty || path == "/" {
            comp.path = "/v1/huawei/summary"
        }
        return comp.url?.absoluteString ?? trimmed
    }

    private func registerURL(from endpointRoot: String) -> URL? {
        var normalized = endpointRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.lowercased().hasPrefix("http://"), !normalized.lowercased().hasPrefix("https://") {
            normalized = "https://" + normalized
        }
        guard var comp = URLComponents(string: normalized) else { return nil }
        comp.path = "/v1/auth/register"
        comp.query = nil
        comp.fragment = nil
        return comp.url
    }

    private func submit() async {
        errorMessage = ""
        let root = serverRoot
        guard !root.isEmpty else {
            errorMessage = "Приложение не настроено: нет адреса сервера в сборке."
            return
        }
        guard let url = registerURL(from: root) else {
            errorMessage = "Некорректный адрес сервера в настройках сборки."
            return
        }
        isSubmitting = true
        defer { isSubmitting = false }

        let body: [String: String] = [
            "fullName": fullName.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
            "password": password,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            errorMessage = "Не удалось сформировать запрос."
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        req.timeoutInterval = 45

        do {
            let (responseData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "Нет ответа от сервера. Проверьте интернет."
                return
            }
            if (200 ... 299).contains(http.statusCode) {
                let normalizedEndpoint = normalizedHuaweiEndpointString(root)
                onRegistered(
                    AlarmRegistrationPayload(
                        fullName: fullName.trimmingCharacters(in: .whitespacesAndNewlines),
                        email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        endpointURL: normalizedEndpoint,
                        accessToken: ""
                    )
                )
                return
            }
            let hint = String(data: responseData, encoding: .utf8) ?? ""
            errorMessage = "Не удалось зарегистрироваться. Попробуйте ещё раз. (\(http.statusCode))"
            if !hint.isEmpty {
                errorMessage += " \(String(hint.prefix(120)))"
            }
        } catch {
            errorMessage = "Проблема с сетью: \(error.localizedDescription)"
        }
    }
}

private struct PaywallView: View {
    let onPayTap: () async -> Void
    let onRefresh: () async -> Void
    @State private var isProcessing = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                VStack(spacing: 18) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "moon.stars.fill")
                                    .foregroundStyle(.indigo.opacity(0.95))
                                Text("The Dream is Over")
                                    .font(.title2.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            Text("Ночные привычки не прощают паузы.")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Text("Чтобы продолжить, откройте полный доступ")
                                .font(.subheadline)
                                .foregroundStyle(Color.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("199 ₽ в месяц • персональные рекомендации • доступ без ограничений")
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Статус профиля: unpaid")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                    PrimaryGradientButton(title: isProcessing ? "Проверяем оплату…" : "Оплатить 199 ₽", systemImage: "creditcard.fill") {
                        guard !isProcessing else { return }
                        isProcessing = true
                        Task {
                            await onPayTap()
                            isProcessing = false
                        }
                    }
                    .opacity(isProcessing ? 0.8 : 1)
                    PrimaryGradientButton(title: isRefreshing ? "Обновляем…" : "Я уже оплатил — обновить статус", systemImage: "arrow.clockwise") {
                        guard !isRefreshing else { return }
                        isRefreshing = true
                        Task {
                            await onRefresh()
                            isRefreshing = false
                        }
                    }
                    .opacity(isRefreshing ? 0.8 : 1)
                }
                .padding(20)
            }
            .navigationTitle("Оплата")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct AlarmSetupStepView: View {
    @ObservedObject var alarmVM: AlarmViewModel
    @ObservedObject var musicAlarmManager: AppleMusicAlarmManager
    let onNext: () -> Void
    let onOpenStats: () -> Void
    let onSignOut: () -> Void
    @StateObject private var healthInsights = DayHealthInsightsStore()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showMelodySettings = false
    @State private var showAppSettings = false
    @State private var showRepeatDetails = false

    var body: some View {
        ZStack {
            gradientBackground
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Spacer()
                        Button {
                            showAppSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                        Button {
                            onOpenStats()
                        } label: {
                            Label("Statistics", systemImage: "chart.bar.fill")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.white.opacity(0.16))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                    Text("Set your wake-up")
                        .font(.largeTitle.weight(.bold))

                    GlassCard {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Sleep duration")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(alarmVM.sleepDurationText)
                                    .font(.system(size: 34, weight: .bold, design: .rounded))
                                    .foregroundStyle(alarmVM.sleepDurationColor)
                                Text("Time left until wake")
                                    .font(.caption)
                                    .foregroundStyle(Color.white.opacity(0.65))
                            }
                            Spacer()
                            ZStack {
                                Circle()
                                    .fill(alarmVM.sleepDurationColor.opacity(0.2))
                                    .frame(width: 62, height: 62)
                                Image(systemName: "bed.double.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(alarmVM.sleepDurationColor)
                            }
                        }
                    }

                    GlassCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Smart Sleep Insights")
                                .font(.headline)
                            if let last = healthInsights.lastHuaweiAutoSyncAt {
                                Text("Updated \(relativeSyncText(from: last))")
                                    .font(.caption2)
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            Text("Sleep-day: \(healthInsights.effectiveAnalyticsDate.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.6))
                            if healthInsights.dataSourceMode == .huaweiAuto && healthInsights.isHuaweiAutoDataStale {
                                Text("Data may be stale until connection is restored.")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            if let summary = healthInsights.summary {
                                HealthMetricTilesBlock(
                                    summary: summary,
                                    isStaleCached: healthInsights.dataSourceMode == .huaweiAuto && healthInsights.isHuaweiAutoDataStale,
                                    isDemoSample: healthInsights.dataSourceMode == .huaweiAuto && healthInsights.huaweiPayloadIsDemo,
                                    useExtendedActivitySlice: summary.stepsAndEnergyAreNightExtendedSlice
                                )
                                .padding(.top, 4)
                                Text(DayHealthTipBuilder.tips(from: summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let top = DayHealthTipBuilder.insights(summary: summary, history: healthInsights.huaweiManualHistory).first {
                                    Text("• \(top)")
                                        .font(.caption2)
                                        .foregroundStyle(Color.white.opacity(0.8))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                if healthInsights.dataSourceMode == .huaweiAuto, !healthInsights.isHuaweiAutoConfigured {
                                    Text("Сейчас выбран источник Huawei, но backend не настроен — цифры с Apple Health не подставятся. Настройки (шестерёнка) → Health services → чип «Apple Health», затем «Разрешить доступ к Health».")
                                        .font(.caption)
                                        .foregroundStyle(.orange.opacity(0.95))
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Text("Подключите Apple Health или Huawei Auto в настройках, чтобы получать персональные рекомендации к вечеру и прогноз бодрости утром.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    GlassCard {
                        Text("Default wake time")
                            .font(.headline)
                        Text("Used for days that have no custom time.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        DatePicker(
                            "",
                            selection: $alarmVM.alarmTime,
                            displayedComponents: [.hourAndMinute]
                        )
                        .labelsHidden()
                        .datePickerStyle(.wheel)
                    }

                    GlassCard {
                        Text("Repeat")
                            .font(.headline)
                        Text("Tap a day to turn it off.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(0 ..< 7, id: \.self) { offset in
                                let cal = Calendar.current
                                let wd = (cal.firstWeekday - 1 + offset) % 7 + 1
                                let sym = cal.veryShortWeekdaySymbols[wd - 1]
                                let on = alarmVM.alarmWeekdays.contains(wd)
                                Button {
                                    alarmVM.toggleAlarmWeekday(wd)
                                } label: {
                                    Text(sym)
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 36, height: 36)
                                        .background(
                                            Circle()
                                                .fill(on ? Color.indigo.opacity(0.6) : Color.white.opacity(0.12))
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .frame(maxWidth: .infinity)

                        let cal = Calendar.current
                        let orderedWeekdays = (0 ..< 7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showRepeatDetails.toggle()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text("Set custom time for each day")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: showRepeatDetails ? "chevron.up" : "chevron.down")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 2)
                        }
                        .buttonStyle(.plain)

                        if showRepeatDetails {
                            VStack(spacing: 8) {
                                ForEach(orderedWeekdays.filter { alarmVM.alarmWeekdays.contains($0) }, id: \.self) { wd in
                                    HStack {
                                        Text(cal.weekdaySymbols[wd - 1])
                                            .font(.subheadline.weight(.semibold))
                                            .frame(minWidth: 82, alignment: .leading)
                                        DatePicker(
                                            "",
                                            selection: alarmVM.bindingForWeekdayTime(wd),
                                            displayedComponents: [.hourAndMinute]
                                        )
                                        .labelsHidden()
                                        .datePickerStyle(.compact)
                                    }
                                }
                            }
                        }
                    }

                    Button {
                        showMelodySettings = true
                    } label: {
                        GlassCard {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Alarm sound")
                                        .font(.headline)
                                    Group {
                                        switch alarmVM.wakeSoundMode {
                                        case .builtIn:
                                            Text("\(alarmVM.alarmSound.category.title) · \(alarmVM.alarmSound.title)")
                                                .font(.subheadline)
                                                .foregroundStyle(Color.white.opacity(0.9))
                                        case .appleMusic:
                                            if let selected = musicAlarmManager.currentSelection {
                                                Text(selected.subtitle)
                                                    .font(.subheadline)
                                                    .foregroundStyle(Color.white.opacity(0.95))
                                                    .lineLimit(3)
                                            } else {
                                                Text("Apple Music — choose a song")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        case .localFile:
                                            if let name = alarmVM.localWakeFileDisplayName {
                                                Text(name)
                                                    .font(.subheadline)
                                                    .foregroundStyle(Color.white.opacity(0.95))
                                                    .lineLimit(3)
                                                if alarmVM.lockScreenNotifyReady {
                                                    Text("Lock screen: your track (first ~30 s) · full track when you open the app")
                                                        .font(.caption2)
                                                        .foregroundStyle(Color.white.opacity(0.65))
                                                        .padding(.top, 2)
                                                } else {
                                                    Text("Preparing lock-screen sound… open Alarm sound and pick the file again if needed.")
                                                        .font(.caption2)
                                                        .foregroundStyle(.orange.opacity(0.9))
                                                        .padding(.top, 2)
                                                }
                                            } else {
                                                Text("Files — choose an MP3 or audio file")
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Color.white.opacity(0.55))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)

                    PrimaryGradientButton(title: "Continue to sound mix") {
                        onNext()
                    }
                }
                .padding(20)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showMelodySettings) {
            AlarmMelodySettingsView(alarmVM: alarmVM, musicAlarmManager: musicAlarmManager)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAppSettings) {
            AlarmAppSettingsSheet(healthInsights: healthInsights, onSignOut: onSignOut)
                .preferredColorScheme(.dark)
        }
        .task {
            await healthInsights.refreshAuthorizationState()
            await healthInsights.reloadSummary()
        }
        .task {
            // Автообновление сводки на первом экране (каждые 5 минут).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await healthInsights.reloadSummary()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await healthInsights.refreshAuthorizationState()
                await healthInsights.reloadSummary()
            }
        }
        .onDisappear {
            AlarmSoundPreview.stop()
            musicAlarmManager.stopPreview()
        }
    }

    private func relativeSyncText(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private struct AlarmAppSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var healthInsights: DayHealthInsightsStore
    let onSignOut: () -> Void
    @State private var snoozeEnabled = AlarmBehaviorSettings.isSnoozeEnabled
    @State private var snoozeMinutes = AlarmBehaviorSettings.snoozeIntervalMinutes
    @State private var snoozeMax = AlarmBehaviorSettings.snoozeMaxCount
    @State private var crescendoOn = AlarmBehaviorSettings.isCrescendoEnabled
    @State private var crescendoSec = Double(AlarmBehaviorSettings.crescendoRampSeconds)
    @State private var alarmVolume = AlarmBehaviorSettings.alarmVolumeMultiplier
    @State private var vibrationOn = AlarmVibrationSettings.isEnabled
    @State private var vibMode = AlarmVibrationSettings.mode
    @State private var interval = AlarmVibrationSettings.pulseIntervalSeconds
    @State private var style = AlarmVibrationSettings.style
    @State private var patternGap = AlarmVibrationSettings.patternRepeatGapSeconds
    @State private var customDraftSamples: [AlarmVibrationSettings.PatternSample] = []

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                settingsForm
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        persist()
                        dismiss()
                    }
                }
            }
            .onAppear {
                snoozeEnabled = AlarmBehaviorSettings.isSnoozeEnabled
                snoozeMinutes = AlarmBehaviorSettings.snoozeIntervalMinutes
                snoozeMax = AlarmBehaviorSettings.snoozeMaxCount
                crescendoOn = AlarmBehaviorSettings.isCrescendoEnabled
                crescendoSec = Double(AlarmBehaviorSettings.crescendoRampSeconds)
                alarmVolume = AlarmBehaviorSettings.alarmVolumeMultiplier
                vibrationOn = AlarmVibrationSettings.isEnabled
                vibMode = AlarmVibrationSettings.mode
                interval = AlarmVibrationSettings.pulseIntervalSeconds
                style = AlarmVibrationSettings.style
                patternGap = AlarmVibrationSettings.patternRepeatGapSeconds
                if vibMode == .customPattern {
                    customDraftSamples = AlarmVibrationSettings.loadCustomPattern()
                }
                Task {
                    await healthInsights.refreshAuthorizationState()
                    await healthInsights.reloadSummary()
                }
            }
            .onChange(of: vibMode) { _, newMode in
                if newMode == .customPattern {
                    customDraftSamples = AlarmVibrationSettings.loadCustomPattern()
                }
            }
            .onDisappear {
                persist()
            }
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                Text(
                    "Короткий сигнал на заблокированном экране — ограничение iOS. Полный звук будильника в приложении идёт по кругу, пока вы его не выключите."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Text("Звук и уведомления")
            }

            Section {
                Text("На шаге 1: время, дни недели, мелодия. Здесь: snooze, нарастание громкости в приложении, вибрация.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Что обычно бывает в будильниках")
            }

            Section {
                NavigationLink {
                    Form {
                        Toggle("Snooze", isOn: $snoozeEnabled)
                        Picker("Интервал snooze", selection: $snoozeMinutes) {
                            Text("5 мин").tag(5)
                            Text("9 мин").tag(9)
                            Text("10 мин").tag(10)
                            Text("15 мин").tag(15)
                            Text("20 мин").tag(20)
                        }
                        .disabled(!snoozeEnabled)
                        Stepper(value: $snoozeMax, in: 0 ... 20) {
                            Text(snoozeMax == 0 ? "Лимит snooze: без лимита" : "Лимит snooze: \(snoozeMax)× за серию")
                        }
                        .disabled(!snoozeEnabled)
                        Toggle("Плавное нарастание громкости", isOn: $crescendoOn)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Длительность нарастания: \(Int(crescendoSec)) с")
                                .font(.subheadline)
                            Slider(value: $crescendoSec, in: 10 ... 120, step: 5)
                        }
                        .disabled(!crescendoOn)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Громкость в приложении: \(Int(alarmVolume * 100))%")
                                .font(.subheadline)
                            Slider(value: $alarmVolume, in: 0.2 ... 1.0, step: 0.05)
                        }
                    }
                    .navigationTitle("Alarm settings")
                } label: {
                    Label("Alarm settings", systemImage: "alarm.fill")
                }
            }

            Section {
                NavigationLink {
                    Form {
                        Toggle("Вибрация у будильника", isOn: $vibrationOn)
                        Picker("Как вибрировать", selection: $vibMode) {
                            ForEach(AlarmVibrationSettings.Mode.allCases) { m in
                                Text(m.title).tag(m)
                            }
                        }
                        .pickerStyle(.segmented)

                        if vibMode == .standard {
                            Picker("Тип", selection: $style) {
                                ForEach(AlarmVibrationSettings.Style.allCases) { s in
                                    Text(s.title).tag(s)
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Интервал между импульсами: \(String(format: "%.1f", interval)) с")
                                    .font(.subheadline)
                                Slider(value: $interval, in: 0.8 ... 6.0, step: 0.1)
                            }
                            Button("Тест — один импульс") {
                                persist()
                                AlarmVibrationSettings.playStandardSamplePulse()
                            }
                            .disabled(!vibrationOn)
                        } else {
                            Picker("Сила вибрации", selection: $style) {
                                ForEach(AlarmVibrationSettings.Style.allCases) { s in
                                    Text(s.title).tag(s)
                                }
                            }
                            AlarmVibrationCustomPatternPad(samples: $customDraftSamples)
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Тишина между повторами рисунка: \(String(format: "%.1f", patternGap)) с")
                                    .font(.subheadline)
                                Slider(value: $patternGap, in: 0.5 ... 7.0, step: 0.1)
                            }
                        }
                    }
                    .navigationTitle("Vibration settings")
                } label: {
                    Label("Vibration settings", systemImage: "iphone.radiowaves.left.and.right")
                }
            }

            RenderBackendSection(store: healthInsights)

            Section {
                NavigationLink {
                    AlarmHealthDaySettingsBlock(store: healthInsights)
                        .navigationTitle("Health services")
                } label: {
                    Label("Health services", systemImage: "heart.text.square.fill")
                }
            }

            Section {
                Text("Smart Alarm · режим сна и микс")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } header: {
                Text("О приложении")
            }

            Section {
                Button(role: .destructive) {
                    persist()
                    healthInsights.clearAccountLinkedCloudDefaults()
                    onSignOut()
                    dismiss()
                } label: {
                    Text("Выйти из аккаунта")
                        .frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Имя, email и доступ к облаку будут сброшены; откроется экран регистрации.")
                    .font(.caption)
            }
        }
    }

    private func persist() {
        AlarmBehaviorSettings.isSnoozeEnabled = snoozeEnabled
        AlarmBehaviorSettings.snoozeIntervalMinutes = snoozeMinutes
        AlarmBehaviorSettings.snoozeMaxCount = snoozeMax
        AlarmBehaviorSettings.isCrescendoEnabled = crescendoOn
        AlarmBehaviorSettings.crescendoRampSeconds = Int(crescendoSec)
        AlarmBehaviorSettings.alarmVolumeMultiplier = alarmVolume
        AlarmVibrationSettings.isEnabled = vibrationOn
        AlarmVibrationSettings.mode = vibMode
        AlarmVibrationSettings.pulseIntervalSeconds = interval
        AlarmVibrationSettings.style = style
        AlarmVibrationSettings.patternRepeatGapSeconds = patternGap
        if vibMode == .customPattern {
            let norm = AlarmVibrationSettings.normalizeCustomPatternTimeline(customDraftSamples)
            if norm.isEmpty {
                AlarmVibrationSettings.clearCustomPattern()
            } else {
                AlarmVibrationSettings.saveCustomPattern(norm)
            }
        }
    }
}

private struct RenderBackendSection: View {
    @ObservedObject var store: DayHealthInsightsStore

    var body: some View {
        Section {
            if store.isHuaweiAutoConfigured {
                Button {
                    Task { await store.syncToRenderBackend() }
                } label: {
                    HStack {
                        if store.renderUploadInProgress {
                            ProgressView()
                                .padding(.trailing, 6)
                        }
                        Text("Выгрузить на Render-сервер")
                    }
                }
                .disabled(store.renderUploadInProgress)
                if let msg = store.lastRenderUploadMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let t = store.lastRenderUploadAt {
                    Text("Последняя выгрузка: \(t.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(
                    "Укажите URL вида https://…/v1/huawei/summary и токен в Health services — это ваш сервис на Render; выгрузка пойдёт на тот же хост (путь /v1/health/daily-upload)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Backend (Render)")
        } footer: {
            Text(
                "Без Supabase и без Apple: только ваш API_TOKEN. Данные пишутся в файл на сервере (на бесплатном Render он может сбрасываться при деплое — для постоянства подключите Postgres на Render)."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct AlarmHealthDaySettingsBlock: View {
    @ObservedObject var store: DayHealthInsightsStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var huaweiAutoEndpoint: String = ""
    @State private var huaweiAutoToken: String = ""
    @State private var showHuaweiConnectSheet = false
    @State private var showConnectedDevicesSheet = false
    @State private var showAdvancedBridge = false

    var body: some View {
        #if os(iOS)
        Group {
            HStack(spacing: 10) {
                serviceBadge(
                    title: "Apple Health",
                    isSelected: store.dataSourceMode == .appleHealth,
                    icon: "heart.fill"
                ) {
                    store.dataSourceMode = .appleHealth
                }
                serviceBadge(
                    title: "Huawei",
                    isSelected: store.dataSourceMode != .appleHealth,
                    icon: "waveform.path.ecg"
                ) {
                    store.dataSourceMode = .huaweiAuto
                }
            }
            .padding(.vertical, 4)

            if store.dataSourceMode == .huaweiManual {
                huaweiAutoContent
            } else if store.dataSourceMode == .huaweiAuto {
                huaweiAutoContent
            } else if !store.isHealthDataAvailable {
                Text("«Здоровье» на этом устройстве недоступно.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                switch store.authorizationState {
                case .unavailable:
                    Text("Не удалось подключиться к Health.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .denied:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Доступ к данным Health отклонён. Включите чтение: шаги, сон, активная энергия для этого приложения.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Важно: Системные Настройки → Здоровье → Данные (или «Доступ к данным и устройствам») → ваше приложение — и включите категории. Кнопка «настройки приложения» открывает другой экран и не даёт переключатели Health.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button("Настройки → Здоровье (система)") {
                                if let u = URL(string: "x-apple-health://") {
                                    UIApplication.shared.open(u)
                                }
                            }
                            .buttonStyle(.bordered)
                            Button("Настройки этого приложения") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.indigo)
                        }
                    }
                case .shouldRequest, .unknown:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Покажем шаги за сегодня, сон прошлой ночью и короткую подсказку к вечеру.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Разрешить доступ к Health") {
                            Task { await store.requestAccess() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }
                case .sharingAuthorized:
                    authorizedContent
                }
            }
            if let err = store.lastErrorMessage, !err.isEmpty {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: store.dataSourceMode) { _, newMode in
            Task { @MainActor in
                if newMode == .appleHealth {
                    await store.refreshAuthorizationState()
                }
                await store.reloadSummary()
            }
        }
        .onAppear {
            if store.dataSourceMode == .huaweiManual {
                // Миграция со старого ручного режима: теперь оставляем только авто-синхронизацию Huawei.
                store.dataSourceMode = .huaweiAuto
            }
            huaweiAutoEndpoint = store.huaweiAutoEndpointURL
            huaweiAutoToken = store.huaweiAutoAccessToken
        }
        .task {
            guard store.dataSourceMode == .huaweiAuto, store.huaweiAutoSyncEnabled else { return }
            await store.syncHuaweiAutoNow()
        }
        .task {
            guard store.dataSourceMode == .huaweiAuto else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000_000) // 15 min
                guard store.huaweiAutoSyncEnabled else { continue }
                await store.syncHuaweiAutoNow()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, store.dataSourceMode == .huaweiAuto, store.huaweiAutoSyncEnabled else { return }
            Task { await store.syncHuaweiAutoNow() }
        }
        .fullScreenCover(isPresented: $showHuaweiConnectSheet) {
            NavigationStack {
                Form {
                    Section("Choose source") {
                        ForEach(DayHealthInsightsStore.HuaweiSourceKind.allCases) { kind in
                            Button {
                                store.huaweiSourceKind = kind
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(kind.title)
                                        Text(kind.subtitle)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if store.huaweiSourceKind == kind {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Section("Huawei account") {
                        Text("Подключите backend-bridge один раз. Дальше шаги, калории и сон подтягиваются автоматически.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Если на сервере MOCK_MODE=true, приложение покажет демо-цифры — они не совпадут с Huawei Health на телефоне, пока не будет живого API.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        TextField("Backend URL (https://.../v1/huawei/summary)", text: $huaweiAutoEndpoint)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("App token", text: $huaweiAutoToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("Connect Huawei") {
                            Task {
                                await store.connectHuaweiAuto(endpointURL: huaweiAutoEndpoint, accessToken: huaweiAutoToken)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.indigo)
                    }

                    Section("Advanced") {
                        Toggle("Show advanced bridge details", isOn: $showAdvancedBridge)
                        Toggle("Automatic background sync", isOn: $store.huaweiAutoSyncEnabled)
                        Picker("Day boundary", selection: $store.analyticsDayCutoffHour) {
                            Text("00:00").tag(0)
                            Text("01:00").tag(1)
                            Text("02:00").tag(2)
                            Text("03:00").tag(3)
                            Text("04:00").tag(4)
                            Text("05:00").tag(5)
                            Text("06:00").tag(6)
                        }
                        .pickerStyle(.menu)
                        Text("From midnight until this time, steps and active calories are summed as calendar yesterday plus today. After the boundary, the interval matches the Health app’s «Сегодня».")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("00:00 = from midnight, only the calendar day (no blend). Use 04:00 for typical «night-owl» sleep. If steps looked wrong at 1–2 a.m., pick 04:00 here and reload.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        if showAdvancedBridge {
                            LabeledContent("Source host", value: store.huaweiAutoHostLabel)
                            if let last = store.lastHuaweiAutoSyncAt {
                                LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                    }
                }
                .navigationTitle("Connect Huawei")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { showHuaweiConnectSheet = false }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showConnectedDevicesSheet) {
            NavigationStack {
                connectedDevicesContent
            }
        }
        #else
        Text(DayHealthTipBuilder.tips(from: nil))
            .font(.caption)
            .foregroundStyle(.secondary)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private var authorizedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаем данные…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let s = store.summary {
                HealthMetricTilesBlock(
                    summary: s,
                    isStaleCached: false,
                    isDemoSample: false,
                    useExtendedActivitySlice: s.stepsAndEnergyAreNightExtendedSlice
                )
            }
            if !store.isLoading, store.appleHealthSummaryHasNoValues {
                Text("Пока нет цифр: в «Здоровье» нет согласованных данных (шаги, сон, энергия) или в iOS: Настройки → Здоровье → Данные → это приложение — не все категории включены. Нажмите «Обновить» после исправления.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(DayHealthTipBuilder.tips(from: store.summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Обновить данные") {
                    Task { await store.reloadSummary() }
                }
                .buttonStyle(.bordered)
                Button("Открыть Здоровье") {
                    if let u = URL(string: "x-apple-health://") { UIApplication.shared.open(u) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var huaweiManualContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ручной Huawei режим отключён. Используйте Huawei Auto для автоматической синхронизации.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var huaweiAutoContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Huawei Auto подключается один раз и дальше синхронизируется автоматически.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !store.isHuaweiAutoConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your device")
                        .font(.subheadline.weight(.semibold))
                    Text("Подключите Huawei один раз, и данные сна/шагов/активности будут подтягиваться автоматически каждый день.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Connect Huawei") {
                        showHuaweiConnectSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(store.isHuaweiAutoConfigured ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(store.isHuaweiAutoConfigured ? "Connected" : "Not connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.isHuaweiAutoConfigured ? .green : .secondary)
                Text("· \(store.huaweiSourceKind.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if store.isHuaweiAutoConfigured {
                    Text("· \(store.huaweiAutoHostLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if store.isHuaweiAutoConfigured {
                Text("Sleep-day: \(store.effectiveAnalyticsDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let s = store.summary {
                    HealthMetricTilesBlock(
                        summary: s,
                        isStaleCached: store.isHuaweiAutoDataStale,
                        isDemoSample: store.huaweiPayloadIsDemo,
                        useExtendedActivitySlice: s.stepsAndEnergyAreNightExtendedSlice
                    )
                        .padding(.top, 4)
                } else if store.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Загружаем шаги и калории…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                } else if store.lastErrorMessage == nil || store.lastErrorMessage?.isEmpty == true {
                    Text("Подождите синхронизацию или нажмите Sync now — здесь появятся шаги, ккал и сон.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }

            HStack {
                Button(store.isHuaweiAutoConfigured ? "Manage connection" : "Connect Huawei") {
                    showHuaweiConnectSheet = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.indigo)

                Button("Connected devices") {
                    showConnectedDevicesSheet = true
                }
                .buttonStyle(.bordered)
                .disabled(!store.isHuaweiAutoConfigured)

                Text(store.huaweiAutoSyncEnabled ? "Auto sync ON" : "Auto sync OFF")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.huaweiAutoSyncEnabled ? .green : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                if store.isHuaweiAutoConfigured {
                    Button("Disconnect", role: .destructive) {
                        store.disconnectHuaweiAuto()
                    }
                    .buttonStyle(.bordered)
                }
            }

            LabeledContent("Connection") {
                Text(store.isHuaweiAutoConfigured ? "Connected · \(store.huaweiAutoHostLabel)" : "Not connected")
                    .foregroundStyle(store.isHuaweiAutoConfigured ? .green : .secondary)
            }

            if let last = store.lastHuaweiAutoSyncAt {
                Text("Updated \(relativeSyncText(from: last))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if store.isHuaweiAutoConfigured && store.isHuaweiAutoDataStale {
                Text("Data may be stale. Last successful sync is old, so these are cached values.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let err = store.lastErrorMessage, !err.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection issue")
                            .font(.caption.weight(.semibold))
                        Text(err)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Retry") {
                        Task { await store.syncHuaweiAutoNow() }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
            }

            Text(DayHealthTipBuilder.tips(from: store.summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("AI Insights")
                    .font(.subheadline.weight(.semibold))
                Text("Сон, движение и калории — как это может влиять на бодрость утром (эвристика, не диагноз).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(
                    Array(DayHealthTipBuilder.insights(summary: store.summary, history: store.huaweiManualHistory).prefix(10).enumerated()),
                    id: \.offset
                ) { _, item in
                    Text("• \(item)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var connectedDevicesContent: some View {
        List {
            Section("Devices") {
                deviceRow(
                    title: "Huawei Watch",
                    subtitle: "Primary wearable source",
                    isConnected: store.huaweiSourceKind == .watch && store.isHuaweiAutoConfigured
                )
                deviceRow(
                    title: "Huawei Health app",
                    subtitle: "Cloud sync provider",
                    isConnected: store.isHuaweiAutoConfigured
                )
            }
            Section("Connection") {
                LabeledContent("Status", value: store.isHuaweiAutoConfigured ? "Connected" : "Not connected")
                LabeledContent("Host", value: store.huaweiAutoHostLabel)
                if let last = store.lastHuaweiAutoSyncAt {
                    LabeledContent("Last sync", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
            Section("Actions") {
                Button("Reconnect") {
                    showConnectedDevicesSheet = false
                    showHuaweiConnectSheet = true
                }
                Button("Re-authorize") {
                    showConnectedDevicesSheet = false
                    showHuaweiConnectSheet = true
                }
                Button("Sync now") {
                    Task { await store.syncHuaweiAutoNow() }
                }
                .disabled(!store.isHuaweiAutoConfigured)
            }
        }
        .navigationTitle("Connected Devices")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { showConnectedDevicesSheet = false }
            }
        }
    }

    @ViewBuilder
    private func deviceRow(title: String, subtitle: String, isConnected: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isConnected ? Color.green : Color.gray.opacity(0.5))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(isConnected ? "Connected" : "Not connected")
                .font(.caption)
                .foregroundStyle(isConnected ? .green : .secondary)
        }
    }

    private func formatSleepHours(_ h: Double) -> String {
        let t = (h * 10).rounded() / 10
        if t == floor(t) {
            return "~\(Int(t)) ч"
        }
        return String(format: "~%.1f ч", t)
    }

    @ViewBuilder
    private func serviceBadge(title: String, isSelected: Bool, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.75))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.indigo.opacity(0.55) : Color.white.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
    }

    private func relativeSyncText(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
    #endif
}

private struct AlarmMelodySettingsView: View {
    @ObservedObject var alarmVM: AlarmViewModel
    @ObservedObject var musicAlarmManager: AppleMusicAlarmManager
    @Environment(\.dismiss) private var dismiss
    @State private var ringtoneCategory: RingtoneCategory = .mechanical
    @State private var showPicker = false
    @State private var showFileImporter = false
    @State private var showAccessError = false
    @State private var importErrorMessage = ""
    @State private var showImportError = false
    @State private var lastSongSavedBanner: String?

    private var builtInSoundBinding: Binding<AlarmSoundOption> {
        Binding(
            get: { alarmVM.alarmSound },
            set: { new in
                alarmVM.alarmSound = new
                alarmVM.persistAlarmSound()
                AlarmSoundPreview.play(new)
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                VStack(alignment: .leading, spacing: 16) {
                    Text("Alarm sound")
                        .font(.largeTitle.bold())
                        .padding(.top, 8)

                    Picker("", selection: $alarmVM.wakeSoundMode) {
                        Text("Built-in").tag(AlarmWakeSoundMode.builtIn)
                        Text("Apple Music").tag(AlarmWakeSoundMode.appleMusic)
                        Text("Files").tag(AlarmWakeSoundMode.localFile)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: alarmVM.wakeSoundMode) { _, mode in
                        switch mode {
                        case .builtIn:
                            musicAlarmManager.stopPreview()
                            AlarmSoundPreview.stop()
                            ringtoneCategory = alarmVM.alarmSound.category
                        case .appleMusic:
                            AlarmSoundPreview.stop()
                        case .localFile:
                            musicAlarmManager.stopPreview()
                            AlarmSoundPreview.stop()
                        }
                    }

                    if alarmVM.wakeSoundMode == .builtIn {
                        Picker("", selection: $ringtoneCategory) {
                            ForEach(RingtoneCategory.allCases) { cat in
                                Text(cat.title).tag(cat)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: ringtoneCategory) { _, newCat in
                            let list = AlarmSoundOption.sounds(for: newCat)
                            if !list.contains(alarmVM.alarmSound), let first = list.first {
                                alarmVM.alarmSound = first
                                alarmVM.persistAlarmSound()
                            }
                            AlarmSoundPreview.play(alarmVM.alarmSound)
                        }

                        Picker("", selection: builtInSoundBinding) {
                            ForEach(AlarmSoundOption.sounds(for: ringtoneCategory)) { sound in
                                Text(sound.title).tag(sound)
                            }
                        }
                        .pickerStyle(.wheel)
                        Text("Предпросмотр здесь — около 25 секунд. В приложении при звонке будильник играет по кругу, пока вы его не выключите.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if alarmVM.wakeSoundMode == .appleMusic {
                        VStack(alignment: .leading, spacing: 12) {
                            if let selected = musicAlarmManager.currentSelection {
                                Text("Alarm will play:")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(selected.subtitle)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                if let banner = lastSongSavedBanner {
                                    Text(banner)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green.opacity(0.95))
                                }
                                HStack(spacing: 16) {
                                    Button("Preview") { musicAlarmManager.previewCurrentSong() }
                                    Button("Clear") {
                                        musicAlarmManager.clearSelection()
                                        alarmVM.wakeSoundMode = .builtIn
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                            } else {
                                Text("Choose a song from your library. It will be the only alarm sound until you switch back to Built-in.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            PrimaryGradientButton(title: "Choose song", systemImage: "music.note.list") {
                                Task {
                                    let granted = await musicAlarmManager.requestAccess()
                                    if granted {
                                        showPicker = true
                                    } else {
                                        showAccessError = true
                                    }
                                }
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Pick MP3, M4A, or WAV from the Files app. We save a copy and prepare a short clip so your sound can play on the lock screen (iOS does not use raw MP3 there). The full file plays when the alarm rings inside the app.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            if let name = alarmVM.localWakeFileDisplayName {
                                Text("Alarm will play:")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(name)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(4)
                                HStack(spacing: 16) {
                                    Button("Preview") {
                                        if let url = AlarmLocalFileStorage.playbackURL() {
                                            AlarmSoundPreview.playFile(at: url)
                                        }
                                    }
                                    Button("Clear", role: .destructive) {
                                        AlarmSoundPreview.stop()
                                        AlarmLocalFileStorage.clear()
                                        alarmVM.localWakeFileDisplayName = nil
                                        alarmVM.wakeSoundMode = .builtIn
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                            }

                            PrimaryGradientButton(title: "Choose audio file", systemImage: "folder") {
                                showFileImporter = true
                            }
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AlarmSoundPreview.stop()
                        musicAlarmManager.stopPreview()
                        dismiss()
                    }
                }
            }
            .alert("Apple Music access denied", isPresented: $showAccessError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Allow Media & Apple Music access in iPhone Settings.")
            }
            .sheet(isPresented: $showPicker) {
                MediaSongPickerSheet(
                    onPick: { item in
                        musicAlarmManager.setSelection(item)
                        alarmVM.wakeSoundMode = .appleMusic
                        if let sel = musicAlarmManager.currentSelection {
                            lastSongSavedBanner = "Saved — \(sel.title)"
                        } else {
                            lastSongSavedBanner = "Saved"
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            lastSongSavedBanner = nil
                        }
                    },
                    onCancel: {}
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.mp3, .mpeg4Audio, .wav, .aiff, .audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    // Важно: доступ security-scoped держим на всё время async-импорта. Если defer был снаружи Task,
                    // он срабатывал до копирования — отсюда «no permission».
                    Task {
                        let access = url.startAccessingSecurityScopedResource()
                        guard access else {
                            await MainActor.run {
                                importErrorMessage = "No access to this file. Pick it again, or copy the file to On My iPhone, then choose it from there."
                                showImportError = true
                            }
                            return
                        }
                        defer { url.stopAccessingSecurityScopedResource() }
                        do {
                            try await AlarmLocalFileStorage.importSecurityScopedFile(from: url)
                            _ = await AlarmLocalFileStorage.prepareLockScreenNotifyClip()
                            await MainActor.run {
                                alarmVM.wakeSoundMode = .localFile
                                alarmVM.localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
                                alarmVM.refreshLockScreenReadiness()
                                alarmVM.persistAlarmSound()
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                        } catch {
                            await MainActor.run {
                                importErrorMessage = error.localizedDescription
                                showImportError = true
                            }
                        }
                    }
                case .failure(let err):
                    importErrorMessage = err.localizedDescription
                    showImportError = true
                }
            }
            .alert("Could not import file", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
            .onAppear {
                ringtoneCategory = alarmVM.alarmSound.category
                alarmVM.localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
            }
            .onDisappear {
                AlarmSoundPreview.stop()
                musicAlarmManager.stopPreview()
            }
        }
    }
}

private struct SoundSetupStepView: View {
    @ObservedObject var sleepVM: SleepViewModel
    @ObservedObject var alarmVM: AlarmViewModel
    /// Уже идёт таймер сна — только правим микс, без повторного «Go to Sleep» и без сброса круга.
    var isEditingActiveSleepSession: Bool = false
    let onStartSleep: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showAlarmScheduleFailed = false

    var body: some View {
        ZStack(alignment: .bottom) {
            SpatialMixerView(sleepVM: sleepVM, bottomExtraPadding: 88)

            LinearGradient(
                colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            .allowsHitTesting(false)

            if isEditingActiveSleepSession {
                PrimaryGradientButton(title: "Готово", systemImage: "checkmark.circle.fill") {
                    dismiss()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            } else {
                PrimaryGradientButton(title: "Go to Sleep", systemImage: "play.fill") {
                    Task { @MainActor in
                        await alarmVM.scheduleMorningAlarm(windowMinutes: sleepVM.wakeWindowMinutes)
                        guard alarmVM.lastScheduledFireDate != nil else {
                            showAlarmScheduleFailed = true
                            return
                        }
                        sleepVM.startSleep()
                        onStartSleep()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .alert("Alarm not scheduled", isPresented: $showAlarmScheduleFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alarmVM.lastErrorMessage ?? "Allow notifications, set alarm sound, then try again.")
        }
        .navigationTitle(isEditingActiveSleepSession ? "Микс для сна" : "Sound Setup")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            if !isEditingActiveSleepSession, !sleepVM.isRunning {
                sleepVM.spatialPlacedSounds = []
            }
        }
        .onDisappear {
            sleepVM.stopSpatialPreview()
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                        Text(isEditingActiveSleepSession ? "Ко сну" : "Back")
                    }
                }
                .tint(.white)
                .transaction { $0.animation = nil }
            }
        }
    }
}

private struct SleepModeStepView: View {
    @ObservedObject var sleepVM: SleepViewModel
    @ObservedObject var alarmVM: AlarmViewModel
    let onExit: () -> Void
    @State private var showSleepMixEditor = false

    var body: some View {
        ZStack {
            gradientBackground
            VStack(spacing: 18) {
                Image(systemName: sleepVM.sleepUIMode == .alarmRinging ? "alarm.fill" : "moon.zzz.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(sleepVM.sleepUIMode == .alarmRinging ? .orange : .indigo)
                    .padding(.top, 24)
                    .shadow(color: (sleepVM.sleepUIMode == .alarmRinging ? Color.orange : Color.indigo).opacity(0.22), radius: 6, x: 0, y: 0)

                Text(sleepVM.sleepUIMode == .alarmRinging ? "Wake up" : "Sleep mode active")
                    .font(.title3.weight(.semibold))

                if sleepVM.sleepUIMode != .alarmRinging {
                    VStack(spacing: 6) {
                        Text("Alarm \(alarmVM.formattedWakeTime)")
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(alarmVM.smartWakeWindowExplanation)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(Color.white.opacity(0.72))
                            .padding(.horizontal, 8)
                    }
                }

                Button {
                    showSleepMixEditor = true
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Микс: \(sleepVM.mixSummaryLabel())")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        Text("Тот же экран, что при настройке звука: перетащите звуки на круг")
                            .font(.caption2)
                            .foregroundStyle(Color.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.1))
                    )
                }
                .buttonStyle(.plain)
                .disabled(sleepVM.sleepUIMode == .alarmRinging)
                .opacity(sleepVM.sleepUIMode == .alarmRinging ? 0.45 : 1)

                Text("Tone: \(Int(sleepVM.brainFrequencyHz)) Hz")
                    .foregroundStyle(Color.white.opacity(0.8))

                if sleepVM.sleepUIMode == .alarmRinging {
                    Text("Time's up — alarm is ringing")
                        .font(.title2.monospacedDigit())
                } else {
                    Text("Auto-off in \(formatted(seconds: sleepVM.remainingSeconds))")
                        .font(.title2.monospacedDigit())
                }

                if sleepVM.sleepUIMode == .alarmRinging {
                    if sleepVM.canSnoozeFromAlarm {
                        Button {
                            Task { await sleepVM.snoozeFromAlarm() }
                        } label: {
                            HStack {
                                Image(systemName: "moon.zzz.fill")
                                Text("Snooze \(AlarmBehaviorSettings.snoozeIntervalMinutes) min")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                            )
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    PrimaryGradientButton(title: "I'm awake", systemImage: "sun.max.fill") {
                        sleepVM.dismissAlarmAndFinish()
                    }
                    .padding(.top, 8)
                } else {
                    PrimaryGradientButton(title: "Stop early", systemImage: "stop.fill") {
                        sleepVM.stopSleep()
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding()
        }
        .navigationTitle(sleepVM.sleepUIMode == .alarmRinging ? "Alarm" : "Sleep Mode")
        .navigationBarBackButtonHidden(true)
        .onAppear {
            sleepVM.syncSleepUIWhenViewAppears()
        }
        .navigationDestination(isPresented: $showSleepMixEditor) {
            SoundSetupStepView(sleepVM: sleepVM, alarmVM: alarmVM, isEditingActiveSleepSession: true) {
                // Уже спим — только возврат из редактора.
            }
            .onDisappear {
                showSleepMixEditor = false
            }
        }
        .onChange(of: sleepVM.isRunning) { _, running in
            if !running {
                onExit()
            }
        }
    }

    private func formatted(seconds: Int) -> String {
        let mins = seconds / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
}

private struct StatsStepView: View {
    @ObservedObject var sleepVM: SleepViewModel

    private var historyRows: [SleepSessionRecord] {
        Array(sleepVM.sessionHistory.prefix(20))
    }

    var body: some View {
        ZStack {
            gradientBackground
            List {
                Section {
                    if let latest = sleepVM.sessionHistory.first {
                        row("Last session", value: latest.startDate.formatted(date: .abbreviated, time: .omitted))
                        row("Sleep duration", value: formatDuration(minutes: latest.durationMinutes))
                        row("Activity level", value: "\(latest.activityLevel)%")
                    } else {
                        Text("No sessions yet. Finish a night with the alarm flow to see duration and activity here.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Overview")
                }

                Section {
                    if sleepVM.sessionHistory.isEmpty {
                        Text("Past nights stack up here — newest first.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(historyRows) { session in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(session.startDate, format: .dateTime.month(.abbreviated).day())
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(formatDuration(minutes: session.durationMinutes))
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(session.recommendation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("History")
                } footer: {
                    if sleepVM.sessionHistory.count > 20 {
                        Text("Showing the 20 most recent sessions.")
                            .font(.caption2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.clear)
        }
        .navigationTitle("Statistics")
    }

    private func formatDuration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 { return "\(m) min" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }
}

private struct WakeResultView: View {
    let session: SleepSessionRecord
    let onContinue: () -> Void
    let onOpenStats: () -> Void

    var body: some View {
        NavigationStack {
            ZStack {
                gradientBackground
                VStack(spacing: 16) {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(.yellow)
                        .padding(.top, 16)

                    Text("Good morning")
                        .font(.title2.bold())

                    Text("Sleep: \(session.durationMinutes / 60)h \(session.durationMinutes % 60)m")
                        .font(.headline)

                    Text(session.recommendation)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button("Continue") { onContinue() }
                            .buttonStyle(.bordered)
                        PrimaryGradientButton(title: "Open Stats") { onOpenStats() }
                    }
                    .controlSize(.large)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Wake Result")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private var gradientBackground: some View {
    LinearGradient(
        colors: [
            Color.black,
            Color(red: 0.06, green: 0.06, blue: 0.13),
            Color(red: 0.10, green: 0.08, blue: 0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
    .ignoresSafeArea()
}

private struct GlassCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1)
        )
    }
}

private struct PrimaryGradientButton: View {
    let title: String
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Spacer()
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.vertical, 14)
            .background(
                LinearGradient(
                    colors: [Color.indigo, Color.purple.opacity(0.9)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
@MainActor
final class AlarmViewModel: ObservableObject {
    @Published var alarmTime: Date = Date()
    /// Дни недели: 1 = воскресенье … 7 = суббота (`Calendar.current`).
    @Published var alarmWeekdays: Set<Int> = AlarmBehaviorSettings.weekdayMask
    /// Минуты от начала суток по конкретному дню недели (1...7).
    @Published var alarmWeekdayTimesMinutes: [Int: Int] = AlarmBehaviorSettings.weekdayTimesMinutes

    @Published var alarmSound: AlarmSoundOption = .mechDigitalBuzzer
    @Published var wakeSoundMode: AlarmWakeSoundMode = .builtIn {
        didSet {
            AlarmWakeSoundModeStorage.set(wakeSoundMode)
            #if canImport(MediaPlayer) && os(iOS)
            if wakeSoundMode == .appleMusic {
                Task { await AlarmAppleMusicPlayback.requestAuthorizationsIfNeeded() }
            }
            #endif
        }
    }
    /// Подпись для карточки «Files» (копия из `AlarmLocalFileStorage`).
    @Published var localWakeFileDisplayName: String? = AlarmLocalFileStorage.displayName()
    /// M4a для уведомления на заблокированном экране готов (ваш звук, не запасной рингтон).
    @Published private(set) var lockScreenNotifyReady: Bool = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()

    @Published private(set) var lastScheduledFireDate: Date?
    @Published private(set) var lastErrorMessage: String?
    private(set) var didRequestNotificationPermission = false

    private let alarmManager: AlarmManager
    private let alarmRingPlayer = AlarmRingPlayer()
    private static let savedAlarmSoundKey = "smartAlarm.selectedSound"
    private static let savedWakeHourKey = "smartAlarm.savedWakeHour"
    private static let savedWakeMinuteKey = "smartAlarm.savedWakeMinute"
    private static let savedWindowKey = "smartAlarm.savedWindow"
    /// Пользователь явно запланировал утро через отдельный экран — тогда при смене времени/таймзоны пересоздаём уведомление.
    private static let morningWakeScheduledKey = "smartAlarm.morningWakeScheduled"
    /// Последняя доставка уведомления, на которую уже подняли полный звук вне режима сна — не повторять при следующем `didBecomeActive`.
    private static let lastHandledWakeDeliveryDateKey = "smartAlarm.lastHandledWakeDeliveryDate"

    /// Сбросить «уже обработали этот пуш» — новое планирование или отбой будильника.
    private static func clearWakeDeliveryLedger() {
        UserDefaults.standard.removeObject(forKey: lastHandledWakeDeliveryDateKey)
    }

    /// Короткий анти-дубль в одном запуске процесса (willPresent + reconcile).
    private var lastStandaloneAlarmStartWallTime: Date?

    init(alarmManager: AlarmManager = AlarmManager()) {
        self.alarmManager = alarmManager
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let saved = AlarmSoundOption.migrated(from: raw) {
            alarmSound = saved
        }
        if let wake = Self.loadSavedWakeDate() {
            alarmTime = wake
        }
        alarmWeekdays = AlarmBehaviorSettings.weekdayMask
        alarmWeekdayTimesMinutes = AlarmBehaviorSettings.weekdayTimesMinutes
        wakeSoundMode = AlarmWakeSoundModeStorage.resolvedMode()
        localWakeFileDisplayName = AlarmLocalFileStorage.displayName()
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func refreshLockScreenReadiness() {
        lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
    }

    func toggleAlarmWeekday(_ weekday: Int) {
        guard (1 ... 7).contains(weekday) else { return }
        var s = alarmWeekdays
        if s.contains(weekday) {
            s.remove(weekday)
            if s.isEmpty { s = Set(1 ... 7) }
        } else {
            s.insert(weekday)
        }
        alarmWeekdays = s
        AlarmBehaviorSettings.weekdayMask = s
    }

    func timeForWeekday(_ weekday: Int) -> Date {
        let calendar = Calendar.current
        let fallback = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let fallbackMinutes = (fallback.hour ?? 7) * 60 + (fallback.minute ?? 0)
        let minutes = alarmWeekdayTimesMinutes[weekday] ?? fallbackMinutes
        let hour = min(23, max(0, minutes / 60))
        let minute = min(59, max(0, minutes % 60))
        var c = calendar.dateComponents([.year, .month, .day], from: Date())
        c.hour = hour
        c.minute = minute
        c.second = 0
        return calendar.date(from: c) ?? alarmTime
    }

    func setTime(_ date: Date, forWeekday weekday: Int) {
        guard (1 ... 7).contains(weekday) else { return }
        let hm = Calendar.current.dateComponents([.hour, .minute], from: date)
        let minutes = min(1439, max(0, (hm.hour ?? 0) * 60 + (hm.minute ?? 0)))
        alarmWeekdayTimesMinutes[weekday] = minutes
        AlarmBehaviorSettings.weekdayTimesMinutes = alarmWeekdayTimesMinutes
    }

    func bindingForWeekdayTime(_ weekday: Int) -> Binding<Date> {
        Binding(
            get: { self.timeForWeekday(weekday) },
            set: { self.setTime($0, forWeekday: weekday) }
        )
    }

    func persistAlarmSound() {
        UserDefaults.standard.set(alarmSound.rawValue, forKey: Self.savedAlarmSoundKey)
    }

    func requestNotificationPermissionIfNeeded() async {
        guard !didRequestNotificationPermission else { return }
        didRequestNotificationPermission = true
        _ = await alarmManager.requestNotificationPermission()
    }

    /// Планирует утренний будильник (уведомления + follow-up). Вызывать перед `startSleep()` и при смене времени.
    func scheduleMorningAlarm(windowMinutes: Int) async {
        persistAlarmSound()
        persistWakeSettings(windowMinutes: windowMinutes)
        let wakeTime = nextOccurrence()
        let wakeWeekday = Calendar.current.component(.weekday, from: wakeTime)
        let selectedSound = alarmSound

        let granted = await alarmManager.requestNotificationPermission()
        guard granted else {
            lastErrorMessage = "Notifications are disabled. Please enable notifications for this app in Settings."
            lastScheduledFireDate = nil
            UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
            return
        }

        if wakeSoundMode == .localFile {
            guard AlarmLocalFileStorage.playbackURL() != nil else {
                lastErrorMessage = "Choose an audio file in Alarm sound first."
                lastScheduledFireDate = nil
                UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
                return
            }
            let lockReady = await AlarmLocalFileStorage.prepareLockScreenNotifyClip()
            guard lockReady else {
                lastErrorMessage = "Your file isn’t ready for the lock screen yet. Open Alarm sound → Files, pick the track again, wait a moment, then try again. If it keeps failing, try M4A or a shorter MP3."
                lastScheduledFireDate = nil
                lockScreenNotifyReady = false
                UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
                return
            }
            lockScreenNotifyReady = true
        } else {
            lockScreenNotifyReady = AlarmLocalFileStorage.hasLockScreenNotifyClipReady()
        }

        let effectiveWindow = effectiveWindowMinutes(baseWindow: windowMinutes)
        let date: Date?
        do {
                date = try await alarmManager.scheduleWakeUpNotification(
                    wakeTime: wakeTime,
                    windowMinutes: effectiveWindow,
                    sound: selectedSound,
                    followupCount: 1,
                    followupIntervalMinutes: 5,
                    weekdays: Set([wakeWeekday])
                )
        } catch {
            lastErrorMessage = "Failed to set alarm. Please try again."
            lastScheduledFireDate = nil
            UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
            return
        }
        lastScheduledFireDate = date
        UserDefaults.standard.set(date != nil, forKey: Self.morningWakeScheduledKey)
        Self.clearWakeDeliveryLedger()
        lastStandaloneAlarmStartWallTime = nil
        AlarmPlaybackAnchor.clear()
        if effectiveWindow == 0 {
            lastErrorMessage = "Less than 1 hour until wake: alarm at the exact time you set (Smart Wake off)."
        } else {
            lastErrorMessage = nil
        }
    }

    func setAlarm(windowMinutes: Int) {
        Task { await scheduleMorningAlarm(windowMinutes: windowMinutes) }
    }

    /// Re-schedule alarm if device time/timezone changed.
    func handleSignificantTimeChange() {
        guard UserDefaults.standard.bool(forKey: Self.morningWakeScheduledKey) else { return }
        guard let savedWake = Self.loadSavedWakeDate() else { return }
        let savedWindow = UserDefaults.standard.integer(forKey: Self.savedWindowKey)
        alarmTime = savedWake
        Task { await scheduleMorningAlarm(windowMinutes: max(0, savedWindow)) }
    }

    /// Smart Wake only when the next alarm is at least one hour away; otherwise exact time.
    var smartWakeExplanation: String {
        let next = nextOccurrence()
        let secondsUntil = next.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return "Smart Wake needs at least 1 hour before wake time. Otherwise the alarm uses your exact time."
        }
        return "Smart Wake: when there’s at least 1 hour before wake, we ring around the middle of the window before your set time (not random)."
    }

    /// После того как пользователь подтвердил пробуждение (уведомления уже сняты в `SleepViewModel`).
    func syncMorningAlarmDismissedState() {
        lastScheduledFireDate = nil
        lastErrorMessage = nil
        UserDefaults.standard.set(false, forKey: Self.morningWakeScheduledKey)
        Self.clearWakeDeliveryLedger()
        lastStandaloneAlarmStartWallTime = nil
        AlarmPlaybackAnchor.clear()
    }

    func clearScheduledMorningAlarm() {
        alarmManager.cancelScheduledMorningAlarm()
        syncMorningAlarmDismissedState()
    }

    /// Полноценный звук будильника при срабатывании уведомления, если режим сна не активен (в т.ч. трек Apple Music из медиатеки).
    func playAlarmFromNotification(notificationDeliveryDate: Date) {
        guard UserDefaults.standard.bool(forKey: Self.morningWakeScheduledKey) else { return }

        let now = Date()
        if let wall = lastStandaloneAlarmStartWallTime, now.timeIntervalSince(wall) < 1.8 {
            return
        }
        if let ts = UserDefaults.standard.object(forKey: Self.lastHandledWakeDeliveryDateKey) as? TimeInterval {
            let lastHandled = Date(timeIntervalSince1970: ts)
            if notificationDeliveryDate <= lastHandled.addingTimeInterval(3) {
                return
            }
        }

        lastStandaloneAlarmStartWallTime = now
        alarmManager.clearWakeRemindersAfterInAppAlarmHandling()
        if let raw = UserDefaults.standard.string(forKey: Self.savedAlarmSoundKey),
           let opt = AlarmSoundOption.migrated(from: raw) {
            alarmSound = opt
        }
        alarmRingPlayer.start(option: alarmSound)
        let prev = (UserDefaults.standard.object(forKey: Self.lastHandledWakeDeliveryDateKey) as? TimeInterval)
            .map { Date(timeIntervalSince1970: $0) }
        let mark = max(prev ?? notificationDeliveryDate, notificationDeliveryDate)
        UserDefaults.standard.set(mark.timeIntervalSince1970, forKey: Self.lastHandledWakeDeliveryDateKey)
    }

    func stopAlarmRingingFromNotification() {
        alarmRingPlayer.stop()
        AlarmPlaybackAnchor.clear()
        clearScheduledMorningAlarm()
    }

    var sleepDurationHours: Int {
        Int(nextOccurrence().timeIntervalSinceNow / 3600)
    }

    var sleepDurationMinutes: Int {
        let totalMinutes = Int(nextOccurrence().timeIntervalSinceNow / 60)
        return max(0, totalMinutes % 60)
    }

    var sleepDurationText: String {
        "\(sleepDurationHours) h \(sleepDurationMinutes) min"
    }

    /// Green 7–9 h; red if under 7 h; yellow if more than 9 h until wake.
    var sleepDurationColor: Color {
        let totalHours = Double(sleepDurationHours) + Double(sleepDurationMinutes) / 60
        if totalHours < 7 { return .red }
        if totalHours <= 9 { return .green }
        return .yellow
    }

    /// Время следующего срабатывания (сегодня или завтра) — для экрана «режим сна».
    var formattedWakeTime: String {
        nextOccurrence().formatted(date: .omitted, time: .shortened)
    }

    /// Текст про окно Smart Wake (после явного «Schedule morning alarm»).
    var smartWakeWindowExplanation: String {
        let next = nextOccurrence()
        let savedWindow = max(0, UserDefaults.standard.integer(forKey: Self.savedWindowKey))
        let windowM = effectiveWindowMinutes(baseWindow: savedWindow)
        let t = next.formatted(date: .omitted, time: .shortened)
        if windowM <= 0 {
            return "Exact alarm at \(t). Smart Wake is off (less than 1 hour until wake)."
        }
        let start = Calendar.current.date(byAdding: .minute, value: -windowM, to: next) ?? next
        let ts = start.formatted(date: .omitted, time: .shortened)
        return "Smart Wake: alarm is scheduled around the middle of \(ts)–\(t) (not random)."
    }

    private func effectiveWindowMinutes(baseWindow: Int) -> Int {
        let nextTarget = nextOccurrence()
        let secondsUntil = nextTarget.timeIntervalSinceNow
        if secondsUntil < 3600 {
            return 0
        }
        return max(0, baseWindow)
    }

    private func nextOccurrence(from now: Date = Date()) -> Date {
        let calendar = Calendar.current
        let active = alarmWeekdays.isEmpty ? Set(1 ... 7) : alarmWeekdays
        let fallbackHM = calendar.dateComponents([.hour, .minute], from: alarmTime)
        let fallbackMinutes = (fallbackHM.hour ?? 7) * 60 + (fallbackHM.minute ?? 0)
        let startOfToday = calendar.startOfDay(for: now)
        var best: Date?
        for dayOffset in 0 ..< 14 {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: startOfToday) else { continue }
            let weekday = calendar.component(.weekday, from: dayStart)
            guard active.contains(weekday) else { continue }
            let minutes = alarmWeekdayTimesMinutes[weekday] ?? fallbackMinutes
            let hour = min(23, max(0, minutes / 60))
            let minute = min(59, max(0, minutes % 60))
            var c = calendar.dateComponents([.year, .month, .day], from: dayStart)
            c.hour = hour
            c.minute = minute
            c.second = 0
            guard let candidate = calendar.date(from: c), candidate > now else { continue }
            if best == nil || candidate < best! {
                best = candidate
            }
        }
        return best ?? now.addingTimeInterval(86_400)
    }

    private func persistWakeSettings(windowMinutes: Int) {
        let calendar = Calendar.current
        let hm = calendar.dateComponents([.hour, .minute], from: alarmTime)
        UserDefaults.standard.set(hm.hour ?? 7, forKey: Self.savedWakeHourKey)
        UserDefaults.standard.set(hm.minute ?? 0, forKey: Self.savedWakeMinuteKey)
        UserDefaults.standard.set(max(0, windowMinutes), forKey: Self.savedWindowKey)
        AlarmBehaviorSettings.weekdayMask = alarmWeekdays
        AlarmBehaviorSettings.weekdayTimesMinutes = alarmWeekdayTimesMinutes
    }

    private static func loadSavedWakeDate() -> Date? {
        guard UserDefaults.standard.object(forKey: savedWakeHourKey) != nil,
              UserDefaults.standard.object(forKey: savedWakeMinuteKey) != nil else {
            return nil
        }
        let hour = UserDefaults.standard.integer(forKey: savedWakeHourKey)
        let minute = UserDefaults.standard.integer(forKey: savedWakeMinuteKey)
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = hour
        components.minute = minute
        components.second = 0
        return Calendar.current.date(from: components)
    }
}

// MARK: - Открыли приложение без тапа по уведомлению (в фоне `smartAlarmDidFire` не приходит).
@MainActor
private func reconcileDeliveredWakeNotifications(sleepVM: SleepViewModel, alarmVM: AlarmViewModel) async {
    let notes = await withCheckedContinuation { (cont: CheckedContinuation<[UNNotification], Never>) in
        UNUserNotificationCenter.current().getDeliveredNotifications { cont.resume(returning: $0) }
    }
    func isWake(_ id: String) -> Bool {
        id == "smart_alarm_wakeup" || id == "smart_alarm_snooze" || id.hasPrefix("smart_alarm_wakeup_followup")
    }
    let wakeNotes = notes.filter { isWake($0.request.identifier) }
    guard !wakeNotes.isEmpty else { return }

    /// Полный звук только если уведомление недавнее; иначе только чистим центр уведомлений.
    let playWindowSeconds: TimeInterval = 75
    let now = Date()
    let freshEnoughToRing = wakeNotes.contains { now.timeIntervalSince($0.date) < playWindowSeconds }

    // Снять баннеры, follow-up и «залипший» pending основного wake до ветвления.
    AlarmManager().clearWakeRemindersAfterInAppAlarmHandling()

    if freshEnoughToRing {
        if let anchorDate = wakeNotes.map(\.date).min() {
            AlarmPlaybackAnchor.recordIfNeeded(anchorDate)
        }
        if sleepVM.isRunning && sleepVM.sleepUIMode == .sleeping {
            sleepVM.handleExternalAlarmFired()
        } else if sleepVM.isRunning && sleepVM.sleepUIMode == .alarmRinging {
            sleepVM.reassertAlarmPlaybackFromForegroundIfNeeded()
        } else if !sleepVM.isRunning, let maxDelivery = wakeNotes.map(\.date).max() {
            alarmVM.playAlarmFromNotification(notificationDeliveryDate: maxDelivery)
        }
    }
}
