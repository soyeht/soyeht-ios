from dataclasses import dataclass


@dataclass(frozen=True)
class ToolSpec:
    order: int
    definition: dict
    handler: object

    @property
    def name(self):
        return self.definition["name"]


_TOOL_SPECS_BY_NAME = {}
_TOOL_NAMES_BY_ORDER = {}


def register_tool(*, order, definition):
    """Declare one MCP tool's public contract and handler in one place."""
    if not isinstance(order, int) or order < 0:
        raise RuntimeError(
            f"MCP tool order must be a non-negative integer, got {order!r}."
        )
    if not isinstance(definition, dict):
        raise RuntimeError("MCP tool definition must be a dictionary.")

    name = definition.get("name")
    if not isinstance(name, str) or not name:
        raise RuntimeError("MCP tool definition requires a non-empty name.")
    if not isinstance(definition.get("description"), str):
        raise RuntimeError(f"MCP tool {name!r} requires a string description.")
    if not isinstance(definition.get("inputSchema"), dict):
        raise RuntimeError(f"MCP tool {name!r} requires an inputSchema object.")

    def decorate(handler):
        existing = _TOOL_SPECS_BY_NAME.get(name)
        if existing is not None:
            raise RuntimeError(
                f"Duplicate MCP tool name {name!r}: "
                f"{existing.handler.__module__}.{existing.handler.__name__} and "
                f"{handler.__module__}.{handler.__name__}."
            )
        existing_name = _TOOL_NAMES_BY_ORDER.get(order)
        if existing_name is not None:
            raise RuntimeError(
                f"Duplicate MCP tool order {order}: {existing_name!r} and {name!r}."
            )

        spec = ToolSpec(order=order, definition=definition, handler=handler)
        _TOOL_SPECS_BY_NAME[name] = spec
        _TOOL_NAMES_BY_ORDER[order] = name
        handler.__soyeht_tool_spec__ = spec
        return handler

    return decorate


def registered_tool_specs():
    return tuple(sorted(_TOOL_SPECS_BY_NAME.values(), key=lambda spec: spec.order))


def build_tool_registry():
    specs = registered_tool_specs()
    orders = tuple(spec.order for spec in specs)
    expected_orders = tuple(range(len(specs)))
    if orders != expected_orders:
        raise RuntimeError(
            "MCP tool order must be contiguous from zero: "
            f"expected {expected_orders!r}, got {orders!r}."
        )
    tools = [spec.definition for spec in specs]
    handlers = {spec.name: spec.handler for spec in specs}
    return specs, tools, handlers
