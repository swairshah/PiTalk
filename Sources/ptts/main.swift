import Foundation
import Network
import PiTalkClient

/// ptts - PiTalk command line interface
///
/// Usage:
///   ptts "Hello world"                    # Enqueue speech in PiTalk broker
///   ptts --voice alba "Hello"             # Use specific voice
///   echo "Hello" | ptts                   # Read from stdin
///   ptts --list-voices                     # List available voices
///   ptts --stop                            # Stop current/queued speech

struct CLI {
    var text: String = ""
    var voice: String? = nil  // nil = let PiTalk auto-assign
    var port: Int = 18080
    var brokerPort: Int = 18081
    var host: String = "127.0.0.1"
    var sessionId: String?
    var listVoices: Bool = false
    var stopSpeech: Bool = false
    var showHelp: Bool = false
    var quiet: Bool = false
}

struct BrokerRequest: Encodable {
    let type: String
    let text: String?
    let voice: String?
    let sourceApp: String?
    let sessionId: String?
    let pid: Int32?
}

struct BrokerResponse: Decodable {
    let ok: Bool?
    let error: String?
    let queued: Int?
    let pending: Int?
    let playing: Bool?
}

func printUsage() {
    let usage = """
    ptts - PiTalk command line text-to-speech

    USAGE:
        ptts [OPTIONS] <TEXT>
        echo "text" | ptts [OPTIONS]

    ARGUMENTS:
        <TEXT>    Text to speak (can also be piped via stdin)

    OPTIONS:
        -v, --voice <VOICE>   Voice to use (default: auto-assigned by PiTalk)
        -p, --port <PORT>     TTS server port (default: 18080)
        -b, --broker-port <PORT>
                              Broker queue port (default: 18081)
        -H, --host <HOST>     Server host (default: 127.0.0.1)
        -S, --session-id <ID> Session identifier attached to broker requests
        -q, --quiet           Suppress status messages
        -l, --list-voices     List available voices
        -s, --stop            Stop current/queued speech
        -h, --help            Show this help message

    EXAMPLES:
        ptts "Hello, world!"
        ptts -v alba "Good morning"
        echo "Long text from file" | ptts
        ptts --session-id pi-session-abc123 "Hello from a specific session"

    VOICES:
        ally, dorothy, lily, alice, dave, joseph
        george, emma, oliver, sophia, charlotte, william, jack, olivia, isla, liam
        draco, pandora, hyperion, theia, angus

    NOTE:
        Requires PiTalk.app to be running.
        Default mode enqueues speech in PiTalk's local broker queue for centralized playback.
    """
    FileHandle.standardError.write(usage.data(using: .utf8)!)
}

func parseArgs() -> CLI {
    var cli = CLI()
    let args = Array(CommandLine.arguments.dropFirst())
    var positionalArgs: [String] = []

    var i = 0
    while i < args.count {
        let arg = args[i]

        switch arg {
        case "-h", "--help":
            cli.showHelp = true
            return cli
        case "-l", "--list-voices":
            cli.listVoices = true
            return cli
        case "-s", "--stop":
            cli.stopSpeech = true
            return cli
        case "-v", "--voice":
            i += 1
            if i < args.count {
                cli.voice = args[i]
            }
        case "-p", "--port":
            i += 1
            if i < args.count, let port = Int(args[i]) {
                cli.port = port
            }
        case "-b", "--broker-port":
            i += 1
            if i < args.count, let brokerPort = Int(args[i]) {
                cli.brokerPort = brokerPort
            }
        case "-H", "--host":
            i += 1
            if i < args.count {
                cli.host = args[i]
            }
        case "-S", "--session-id":
            i += 1
            if i < args.count {
                cli.sessionId = args[i]
            }
        case "-q", "--quiet":
            cli.quiet = true
        default:
            if arg.hasPrefix("-") {
                FileHandle.standardError.write("Unknown option: \(arg)\n".data(using: .utf8)!)
            } else {
                positionalArgs.append(arg)
            }
        }
        i += 1
    }

    cli.text = positionalArgs.joined(separator: " ")
    return cli
}

func sendBrokerCommand(host: String, port: Int, request: BrokerRequest, timeout: TimeInterval = 3.0) async throws -> BrokerResponse {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
        throw TTSError.serverError("Invalid broker port: \(port)")
    }

    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

    return try await withCheckedThrowingContinuation { continuation in
        let queue = DispatchQueue(label: "ptts.broker")
        var resumed = false
        var buffer = Data()

        let timeoutWork = DispatchWorkItem {
            if resumed { return }
            resumed = true
            connection.cancel()
            continuation.resume(throwing: TTSError.serverError("PiTalk broker timeout"))
        }

        func resolve(_ result: Result<BrokerResponse, Error>) {
            if resumed { return }
            resumed = true
            timeoutWork.cancel()
            connection.cancel()
            continuation.resume(with: result)
        }

        func parseResponse(_ data: Data) {
            guard !data.isEmpty else {
                resolve(.failure(TTSError.serverError("Empty broker response")))
                return
            }

            do {
                let response = try JSONDecoder().decode(BrokerResponse.self, from: data)
                resolve(.success(response))
            } catch {
                resolve(.failure(TTSError.serverError("Invalid broker response")))
            }
        }

        func receiveResponse() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    resolve(.failure(error))
                    return
                }

                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let line = buffer.prefix(upTo: newlineIndex)
                        parseResponse(Data(line))
                        return
                    }
                }

                if isComplete {
                    parseResponse(buffer)
                } else {
                    receiveResponse()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                do {
                    var payload = try JSONEncoder().encode(request)
                    payload.append(0x0A)
                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            resolve(.failure(error))
                            return
                        }
                        receiveResponse()
                    })
                } catch {
                    resolve(.failure(error))
                }

            case .failed(let error):
                resolve(.failure(error))

            case .cancelled:
                break

            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        connection.start(queue: queue)
    }
}

func checkBrokerHealth(host: String, brokerPort: Int) async throws {
    let response = try await sendBrokerCommand(
        host: host,
        port: brokerPort,
        request: BrokerRequest(type: "health", text: nil, voice: nil, sourceApp: nil, sessionId: nil, pid: nil)
    )

    if response.ok != true {
        throw TTSError.serverError(response.error ?? "PiTalk broker not healthy")
    }
}

func stopViaBroker(host: String, brokerPort: Int) async throws {
    let response = try await sendBrokerCommand(
        host: host,
        port: brokerPort,
        request: BrokerRequest(type: "stop", text: nil, voice: nil, sourceApp: "ptts", sessionId: nil, pid: getpid())
    )

    if response.ok != true {
        throw TTSError.serverError(response.error ?? "Broker stop failed")
    }
}

func enqueueViaBroker(host: String, brokerPort: Int, text: String, voice: String?, sessionId: String?) async throws -> BrokerResponse {
    let response = try await sendBrokerCommand(
        host: host,
        port: brokerPort,
        request: BrokerRequest(type: "speak", text: text, voice: voice, sourceApp: "ptts", sessionId: sessionId, pid: getpid())
    )

    if response.ok != true {
        throw TTSError.serverError(response.error ?? "Broker enqueue failed")
    }

    return response
}

func main() async {
    let cli = parseArgs()

    if cli.showHelp {
        printUsage()
        exit(0)
    }

    if cli.listVoices {
        print("Available voices:")
        for voice in TTSClient.availableVoices {
            print("  \(voice)")
        }
        exit(0)
    }

    let client = TTSClient(host: cli.host, port: cli.port)

    if cli.stopSpeech {
        do {
            try await stopViaBroker(host: cli.host, brokerPort: cli.brokerPort)
            if !cli.quiet {
                FileHandle.standardError.write("Speech stopped.\n".data(using: .utf8)!)
            }
            exit(0)
        } catch {
            FileHandle.standardError.write("Error stopping speech: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }

    // Get text from args or stdin
    var text = cli.text

    if text.isEmpty {
        // Check if stdin has data (isatty returns 0 when NOT a tty, i.e., piped input)
        if isatty(STDIN_FILENO) == 0 {
            if let stdinData = try? FileHandle.standardInput.readToEnd(),
               let stdinText = String(data: stdinData, encoding: .utf8) {
                text = stdinText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    if text.isEmpty {
        FileHandle.standardError.write("Error: No text provided. Use ptts --help for usage.\n".data(using: .utf8)!)
        exit(1)
    }

    // Validate voice if explicitly specified
    if let voice = cli.voice, !TTSClient.availableVoices.contains(voice) {
        FileHandle.standardError.write("Warning: Unknown voice '\(voice)'\n".data(using: .utf8)!)
    }

    // Check server health
    do {
        let healthy = try await client.healthCheck()
        if !healthy {
            throw TTSError.serverNotRunning
        }
    } catch {
        FileHandle.standardError.write("Error: \(TTSError.serverNotRunning.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }

    // Speak
    do {
        try await checkBrokerHealth(host: cli.host, brokerPort: cli.brokerPort)
        let response = try await enqueueViaBroker(host: cli.host, brokerPort: cli.brokerPort, text: text, voice: cli.voice, sessionId: cli.sessionId)
        if !cli.quiet {
            if let queued = response.queued {
                FileHandle.standardError.write("Enqueued speech job (queue size: \(queued)).\n".data(using: .utf8)!)
            } else {
                FileHandle.standardError.write("Enqueued speech job.\n".data(using: .utf8)!)
            }
        }
    } catch {
        FileHandle.standardError.write("Error: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}

// Run async main
let semaphore = DispatchSemaphore(value: 0)
Task {
    await main()
    semaphore.signal()
}
semaphore.wait()
