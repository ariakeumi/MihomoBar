import SwiftUI

extension MenuBarRoot {
    var quickRowTrailingColumnWidth: CGFloat {
        min(170, max(126, contentWidth * 0.44))
    }

    var proxyTabBody: some View {
        VStack(alignment: .leading, spacing: MenuBarLayoutTokens.sectionGap) {
            self.trafficOverview
            if !appState.sortedProxyProviderNames.isEmpty {
                proxyProvidersSection
            }
            proxyGroupsSection
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var trafficOverview: some View {
        let sparklineHeight: CGFloat = 64
        let sparklineHorizontalInset = MenuBarLayoutTokens.hRow

        return VStack(alignment: .leading, spacing: MenuBarLayoutTokens.vDense + 2) {
            ZStack {
                TrafficSparklineView(
                    upValues: appState.trafficHistoryUp,
                    downValues: appState.trafficHistoryDown)
                    .frame(height: sparklineHeight)
                    .padding(.horizontal, sparklineHorizontalInset)

                VStack(spacing: 0) {
                    HStack(spacing: MenuBarLayoutTokens.hDense) {
                        Spacer(minLength: 0)

                        self.cornerMetric(
                            value: ValueFormatter.speed(
                                appState.traffic.up,
                                unit: appState.trafficIndicatorUnit),
                            color: nativeInfo,
                            showsIcon: false,
                            iconTrailing: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: MenuBarLayoutTokens.hDense) {
                        Spacer(minLength: 0)

                        self.cornerMetric(
                            value: ValueFormatter.speed(
                                appState.traffic.down,
                                unit: appState.trafficIndicatorUnit),
                            color: nativePositive.opacity(0.92),
                            showsIcon: false,
                            iconTrailing: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(.horizontal, MenuBarLayoutTokens.hRow)
                .padding(.vertical, MenuBarLayoutTokens.vDense)
            }
            .frame(height: sparklineHeight)

            HStack(spacing: MenuBarLayoutTokens.hDense) {
                self.cornerMetric(
                    symbol: "link",
                    value: "\(appState.connectionsCount)",
                    color: nativeIndigo)
                    .frame(maxWidth: .infinity, alignment: .leading)

                self.cornerMetric(
                    symbol: "memorychip",
                    value: ValueFormatter.bytesInteger(appState.memory.inuse),
                    color: nativeTeal)
                    .frame(maxWidth: .infinity, alignment: .leading)

                self.cornerMetric(
                    symbol: "arrow.up.circle",
                    value: ValueFormatter.bytesOrDash(
                        appState.displayUpTotal,
                        unit: appState.trafficIndicatorUnit),
                    color: nativeInfo)
                    .frame(maxWidth: .infinity, alignment: .leading)

                self.cornerMetric(
                    symbol: "arrow.down.circle",
                    value: ValueFormatter.bytesOrDash(
                        appState.displayDownTotal,
                        unit: appState.trafficIndicatorUnit),
                    color: nativePositive.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, MenuBarLayoutTokens.hRow)
        }
        .padding(.top, MenuBarLayoutTokens.vDense)
    }

    func cornerMetric(
        symbol: String = "",
        value: String,
        color: Color,
        showsIcon: Bool = true,
        iconTrailing: Bool = false) -> some View
    {
        let icon = Image(systemName: symbol)
            .font(.appSystem(size: 11, weight: .semibold))
            .foregroundStyle(color)
        let text = Text(value)
            .font(.appMonospaced(size: 12, weight: .regular))
            .foregroundStyle(nativeSecondaryLabel)
            .lineLimit(1)
            .minimumScaleFactor(0.80)

        return HStack(spacing: iconTrailing ? MenuBarLayoutTokens.hMicro : MenuBarLayoutTokens.hMicro + 1) {
            if showsIcon {
                if iconTrailing { text; icon } else { icon; text }
            } else {
                text
            }
        }
    }

    func quickRowContent(
        title: String,
        symbol: String,
        foreground: Color,
        background: Color,
        @ViewBuilder trailing: () -> some View) -> some View
    {
        HStack(spacing: MenuBarLayoutTokens.hDense) {
            self.quickIcon(symbol: symbol, foreground: foreground, background: background)
            Text(title)
                .font(.appSystem(size: 12, weight: .medium))
                .foregroundStyle(nativePrimaryLabel)
            Spacer(minLength: 0)
            trailing()
                .frame(width: self.quickRowTrailingColumnWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MenuBarLayoutTokens.hRow)
        .padding(.vertical, MenuBarLayoutTokens.vDense + 1)
    }

    // swiftlint:disable:next function_parameter_count
    func quickActionRow(
        title: String,
        symbol: String,
        foreground: Color,
        background: Color,
        disabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View) -> some View
    {
        Button(action: action) {
            self.quickRowContent(
                title: title,
                symbol: symbol,
                foreground: foreground,
                background: background)
            {
                trailing()
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }

    // swiftlint:disable:next function_parameter_count
    func quickAsyncRow(
        title: String,
        symbol: String,
        foreground: Color,
        background: Color,
        disabled: Bool = false,
        action: @escaping () async -> Void,
        @ViewBuilder trailing: () -> some View) -> some View
    {
        self.quickActionRow(
            title: title,
            symbol: symbol,
            foreground: foreground,
            background: background,
            disabled: disabled,
            action: {
                Task { await action() }
            },
            trailing: trailing)
    }

    func quickIcon(symbol: String, foreground: Color, background: Color) -> some View {
        RoundedRectangle(cornerRadius: MenuBarLayoutTokens.iconCornerRadius, style: .continuous)
            .fill(background)
            .frame(
                width: MenuBarLayoutTokens.rowLeadingIconSize,
                height: MenuBarLayoutTokens.rowLeadingIconSize)
            .overlay {
                Image(systemName: symbol)
                    .font(.appSystem(size: 12, weight: .semibold))
                    .foregroundStyle(foreground)
            }
    }
}
