import ClaudioCore
import Foundation

/// A browsing identity, never a configuration snapshot or a retained write capability.
package struct SettingsLocation: Equatable, Sendable {
    package let route: SettingsRoute
    package let workspaceRoute: EventSettingsWindowRoute?
    package let viewedPackID: String?

    package init(
        route: SettingsRoute, workspaceRoute: EventSettingsWindowRoute? = nil,
        viewedPackID: String? = nil
    ) {
        self.route = route
        self.workspaceRoute = workspaceRoute
        self.viewedPackID = viewedPackID
    }

    package var destination: SettingsDestination { route.destination }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.browsingRoute == rhs.browsingRoute && lhs.workspaceRoute == rhs.workspaceRoute
            && lhs.viewedPackID == rhs.viewedPackID
    }

    private var browsingRoute: SettingsRoute {
        switch route {
        case .destination(.sounds): return .sounds(.overview)
        case .destination(.eventsAndSounds):
            if let workspaceRoute {
                return .events(scope: workspaceRoute.scope, event: workspaceRoute.event)
            }
            return route
        default: return route
        }
    }

    package func resolve(
        availability: SettingsRouteAvailability, config: ClaudioConfig
    ) -> SettingsRouteResolution {
        let resolution = resolveSettingsRoute(route, availability: availability)
        guard resolution.failure == nil else { return resolution }
        if let workspaceRoute,
            (!availability.eventScopes.contains(workspaceRoute.scope)
                || !workspaceRoute.workspaceTargetIsCurrent(in: config))
        {
            return SettingsRouteResolution(
                route: route, failure: .staleSoundScope(workspaceRoute.scope))
        }
        if case .sounds(let sounds) = route, let target = sounds.workspaceTarget {
            guard sounds.scope == .workspace(target.id),
                config.workspaceRules.contains(where: {
                    $0.id == target.id && $0.directory == target.directory
                })
            else {
                return SettingsRouteResolution(
                    route: route, failure: .staleSoundScope(sounds.scope))
            }
        }
        if destination == .sounds, let viewedPackID,
            availability.soundPackSnapshotIsFresh,
            !availability.soundPackIDs.contains(viewedPackID)
        {
            return SettingsRouteResolution(route: route, failure: .staleSoundPack(viewedPackID))
        }
        return resolution
    }
}
