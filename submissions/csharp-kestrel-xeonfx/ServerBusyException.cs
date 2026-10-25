using System;

namespace Conduit;

/// <summary>A queue the request needed was full: the server refuses it at once (503) instead of queueing without limit.</summary>
public sealed class ServerBusyException(string message) : Exception(message);
