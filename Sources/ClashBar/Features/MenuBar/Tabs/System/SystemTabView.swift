import SwiftUI

extension MenuBarRoot {
    var settingsMenuControlWidth: CGFloat {
        min(152, max(118, contentWidth * 0.43))
    }

    var settingsPortFieldWidth: CGFloat {
        min(108, max(92, contentWidth * 0.30))
    }

    var settingsTextFieldWidth: CGFloat {
        min(230, max(148, contentWidth * 0.56))
    }

    var maintenanceActionEnabled: Bool {
        appState.isRuntimeRunning
    }

    var portAutoSaving: Bool {
        appState.settingsSyncingKey == "ports-auto" || appState.settingsSyncingKey == "ports"
    }

    var settingsFeedbackState: (message: String, color: Color, symbol: String)? {
        if let error = appState.settingsErrorMessage.trimmedNonEmpty {
            return (error, nativeCritical.opacity(0.92), "exclamationmark.triangle.fill")
        }

        if let saved = appState.settingsSavedMessage.trimmedNonEmpty {
            return (saved, nativePositive.opacity(0.92), "checkmark.circle.fill")
        }

        return nil
    }

    func editableCoreSettingBinding(_ setting: AppState.EditableCoreSetting) -> Binding<Bool> {
        Binding(
            get: { self.appState.boolValue(for: setting) },
            set: { value in
                Task { await self.appState.applyEditableCoreSetting(setting, to: value) }
            })
    }

    var systemTabBody: some View {
        let proxyPortFields: [(titleKey: String, symbol: String, text: Binding<String>)] = [
            ("ui.settings.port.port", "network", $appState.settingsPort),
            ("ui.settings.port.socks", "wave.3.right", $appState.settingsSocksPort),
            ("ui.settings.port.mixed", "arrow.triangle.merge", $appState.settingsMixedPort),
            ("ui.settings.port.redir", "arrowshape.turn.up.right", $appState.settingsRedirPort),
            ("ui.settings.port.tproxy", "shield.lefthalf.filled", $appState.settingsTProxyPort),
        ]
        let remoteToggleItems: [(id: String, title: String, symbol: String, isOn: Binding<Bool>)] = [
            (
                AppState.EditableCoreSetting.allowLan.id,
                tr("ui.settings.allow_lan"),
                "network",
                self.editableCoreSettingBinding(.allowLan)),
            (
                AppState.EditableCoreSetting.ipv6.id,
                tr("ui.settings.ipv6"),
                "globe",
                self.editableCoreSettingBinding(.ipv6)),
            (
                AppState.EditableCoreSetting.tcpConcurrent.id,
                tr("ui.settings.tcp_concurrent"),
                "point.3.connected.trianglepath.dotted",
                self.editableCoreSettingBinding(.tcpConcurrent)),
            (
                AppState.EditableCoreSetting.tunMode.id,
                tr("ui.settings.tun_mode"),
                "shield.lefthalf.filled",
                self.editableCoreSettingBinding(.tunMode)),
        ]
        let maintenanceActions: [(titleKey: String, symbol: String, action: @MainActor () async -> Void)] = [
            ("ui.action.flush_fakeip_cache", "externaldrive.badge.minus", { await appState.flushFakeIPCache() }),
            ("ui.action.flush_dns_cache", "network.badge.shield.half.filled", { await appState.flushDNSCache() }),
        ]
        let selectedLogLevel = appState.stringValue(for: .logLevel)

        return VStack(alignment: .leading, spacing: MenuBarLayoutTokens.sectionGap) {
            if let feedback = settingsFeedbackState {
                settingsFeedbackBanner(
                    text: feedback.message,
                    color: feedback.color,
                    symbol: feedback.symbol)
            }

            VStack(spacing: 0) {
                settingsCardHeader(
                    tr("ui.settings.controller_section"),
                    symbol: "network")
                settingsTextFieldRow(
                    tr("ui.settings.controller_address"),
                    symbol: "network",
                    text: $appState.controllerInput,
                    placeholder: "http://127.0.0.1:9090",
                    monospaced: true)
                {
                    Task { await appState.saveControllerSettings() }
                }
                settingsSecureFieldRow(
                    tr("ui.settings.controller_secret"),
                    symbol: "key.horizontal",
                    text: $appState.controllerSecretInput,
                    placeholder: tr("ui.settings.controller_secret_placeholder"))
                {
                    Task { await appState.saveControllerSettings() }
                }
                settingsInfoRow(
                    tr("ui.settings.connection_state"),
                    symbol: "bolt.horizontal.circle",
                    value: appState.statusText)

                VStack(alignment: .leading, spacing: MenuBarLayoutTokens.vDense + 2) {
                    HStack(spacing: MenuBarLayoutTokens.hDense) {
                        Button {
                            Task { await appState.saveControllerSettings() }
                        } label: {
                            Label(tr("ui.action.save_and_connect"), systemImage: "tray.and.arrow.down")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.isCoreActionProcessing)

                        Button {
                            Task { await appState.reconnectRemoteController() }
                        } label: {
                            Label(tr("ui.action.reconnect"), systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!appState.isPrimaryCoreActionEnabled)

                        if let controllerUIURL = URL(string: appState.controllerUIURL) {
                            Link(destination: controllerUIURL) {
                                Label(tr("ui.action.open_controller_ui"), systemImage: "arrow.up.forward.square")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Label(tr("ui.action.open_controller_ui"), systemImage: "arrow.up.forward.square")
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 4)
                                .foregroundStyle(nativeTertiaryLabel)
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 8,
                                        style: .continuous)
                                        .stroke(nativeControlBorder.opacity(0.8), lineWidth: 0.7)
                                }
                                .opacity(0.6)
                        }
                    }
                }
                .menuRowPadding(vertical: MenuBarLayoutTokens.vDense + 2)
            }

            VStack(spacing: 0) {
                settingsCardHeader(
                    tr("ui.section.remote_core_settings"),
                    symbol: "slider.horizontal.3")
                settingsSelectionRow(
                    tr("ui.settings.core_mode"),
                    symbol: "line.3.horizontal.decrease.circle",
                    valueText: coreModeLabel(appState.currentMode),
                    options: [.rule, .global, .direct],
                    optionTitle: self.coreModeLabel,
                    isSelected: { appState.currentMode == $0 },
                    onSelect: { mode in
                        Task { await appState.switchMode(to: mode) }
                    })
                    .disabled(!appState.isModeSwitchEnabled)
                    .opacity(appState.isModeSwitchEnabled ? 1 : 0.6)
                ForEach(remoteToggleItems, id: \.id) { item in
                    settingsToggleRow(item.title, symbol: item.symbol, isOn: item.isOn)
                }
                settingsSelectionRow(
                    tr("ui.settings.log_level"),
                    symbol: "text.alignleft",
                    valueText: selectedLogLevel,
                    options: ConfigLogLevel.allCases,
                    optionTitle: \.rawValue,
                    isSelected: { selectedLogLevel.caseInsensitiveCompare($0.rawValue) == .orderedSame },
                    onSelect: { level in
                        Task { await appState.applyEditableCoreSetting(.logLevel, to: level.rawValue) }
                    })
            }

            VStack(spacing: 0) {
                settingsCardHeader(
                    tr("ui.section.proxy_ports"),
                    symbol: "point.3.connected.trianglepath.dotted")

                VStack(alignment: .leading, spacing: MenuBarLayoutTokens.vDense + 2) {
                    HStack(spacing: MenuBarLayoutTokens.hDense) {
                        Text(tr("ui.settings.ports_auto_save_hint"))
                            .font(.appSystem(size: 11, weight: .regular))
                            .foregroundStyle(nativeSecondaryLabel)

                        Spacer(minLength: 0)

                        if self.portAutoSaving {
                            HStack(spacing: MenuBarLayoutTokens.hMicro + 1) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(tr("ui.settings.ports_auto_saving"))
                                    .font(.appSystem(size: 10, weight: .medium))
                                    .foregroundStyle(nativeSecondaryLabel)
                            }
                        }
                    }

                    ForEach(proxyPortFields, id: \.titleKey) { item in
                        settingsPortFieldRow(
                            tr(item.titleKey),
                            symbol: item.symbol,
                            text: item.text)
                    }
                }
                .menuRowPadding(vertical: MenuBarLayoutTokens.vDense + 2)
            }

            VStack(spacing: 0) {
                settingsCardHeader(
                    tr("ui.section.app_settings"),
                    symbol: "paintpalette")
                settingsSelectionRow(
                    tr("ui.settings.menu_bar_style"),
                    symbol: "menubar.rectangle",
                    valueText: statusBarModeLabel(appState.statusBarDisplayMode),
                    options: StatusBarDisplayMode.allCases,
                    optionTitle: self.statusBarModeLabel,
                    isSelected: { appState.statusBarDisplayMode == $0 },
                    onSelect: { appState.statusBarDisplayMode = $0 })
                settingsSelectionRow(
                    tr("ui.settings.traffic_indicator_unit"),
                    symbol: "arrow.left.arrow.right",
                    valueText: trafficIndicatorUnitLabel(appState.trafficIndicatorUnit),
                    options: TrafficIndicatorUnit.allCases,
                    optionTitle: self.trafficIndicatorUnitLabel,
                    isSelected: { appState.trafficIndicatorUnit == $0 },
                    onSelect: { appState.trafficIndicatorUnit = $0 })
                settingsSelectionRow(
                    tr("ui.settings.proxy_group_font_size"),
                    symbol: "textformat.size",
                    valueText: proxyGroupFontSizeLabel(appState.proxyGroupFontSize),
                    options: ProxyGroupFontSize.allCases,
                    optionTitle: self.proxyGroupFontSizeLabel,
                    isSelected: { appState.proxyGroupFontSize == $0 },
                    onSelect: { appState.proxyGroupFontSize = $0 })
                settingsToggleRow(
                    tr("ui.settings.menu_bar_openwrt_traffic"),
                    symbol: "waveform.path.ecg",
                    isOn: Binding(
                        get: { appState.menuBarShowsOpenWrtTraffic },
                        set: { appState.menuBarShowsOpenWrtTraffic = $0 }))
                if appState.menuBarShowsOpenWrtTraffic {
                    settingsTextFieldRow(
                        tr("ui.settings.openwrt_host"),
                        symbol: "network",
                        text: $appState.openWrtEndpointInput,
                        placeholder: tr("ui.settings.openwrt_host_placeholder"),
                        monospaced: true)
                    settingsTextFieldRow(
                        tr("ui.settings.openwrt_interface"),
                        symbol: "cable.connector",
                        text: $appState.openWrtInterfaceInput,
                        placeholder: tr("ui.settings.openwrt_interface_placeholder"),
                        monospaced: true)
                    settingsTextFieldRow(
                        tr("ui.settings.openwrt_username"),
                        symbol: "person.crop.circle",
                        text: $appState.openWrtUsernameInput,
                        placeholder: tr("ui.settings.openwrt_username_placeholder"))
                    settingsSecureFieldRow(
                        tr("ui.settings.openwrt_password"),
                        symbol: "key.horizontal",
                        text: $appState.openWrtPasswordInput,
                        placeholder: tr("ui.settings.openwrt_password_placeholder"))
                }
                settingsSelectionRow(
                    tr("ui.settings.language"),
                    symbol: "character.book.closed",
                    valueText: appState.uiLanguage == .zhHans ? tr("ui.language.zh_hans") : tr("ui.language.en"),
                    options: AppLanguage.allCases,
                    optionTitle: { $0 == .zhHans ? tr("ui.language.zh_hans") : tr("ui.language.en") },
                    isSelected: { appState.uiLanguage == $0 },
                    onSelect: appState.setUILanguage)
                settingsSelectionRow(
                    tr("ui.settings.appearance"),
                    symbol: "circle.lefthalf.filled",
                    valueText: appearanceModeLabel(appState.appearanceMode),
                    options: AppAppearanceMode.allCases,
                    optionTitle: self.appearanceModeLabel,
                    isSelected: { appState.appearanceMode == $0 },
                    onSelect: appState.setAppearanceMode)
            }

            VStack(spacing: 0) {
                settingsCardHeader(
                    tr("ui.section.maintenance"),
                    symbol: "wrench.and.screwdriver")

                VStack(alignment: .leading, spacing: MenuBarLayoutTokens.vDense + 2) {
                    HStack(spacing: MenuBarLayoutTokens.hDense) {
                        ForEach(maintenanceActions, id: \.titleKey) { item in
                            maintenanceActionButton(tr(item.titleKey), symbol: item.symbol) {
                                await item.action()
                            }
                        }
                    }
                }
                .menuRowPadding(vertical: MenuBarLayoutTokens.vDense + 2)
            }
        }
    }
}
