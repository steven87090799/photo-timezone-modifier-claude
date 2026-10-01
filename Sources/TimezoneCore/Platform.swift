import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc

// Foundation on Linux does not need Objective-C autorelease pools.
func autoreleasepool<T>(invoking body: () throws -> T) rethrows -> T { try body() }
#endif

func releaseUnusedPages() {
    #if canImport(Darwin)
    _ = malloc_zone_pressure_relief(nil, 0)
    #endif
}
