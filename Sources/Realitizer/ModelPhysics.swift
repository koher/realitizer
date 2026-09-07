public enum ModelPhysicsMode: String, Sendable { case `static`, kinematic, dynamic }

public struct ModelPhysicsDefinition: Sendable {
    public var mode: ModelPhysicsMode
    public var mass: Float
    public var friction: Float
    public var restitution: Float
    public init(mode: ModelPhysicsMode, mass: Float = 1, friction: Float = 0.5, restitution: Float = 0) {
        self.mode = mode
        self.mass = mass
        self.friction = friction
        self.restitution = restitution
    }
}
