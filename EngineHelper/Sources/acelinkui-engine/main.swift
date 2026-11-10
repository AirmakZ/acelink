import Foundation

// Usage:
//   acelinkui-engine prepare --image <ref>
//       Downloads the kernel, the VM's init filesystem and the engine image, and unpacks
//       the image's root filesystem. Safe to run again: whatever is there is reused.
//   acelinkui-engine run --image <ref> --share <dir> [--port <n>]... -- <engine arguments>
//       Boots the engine VM and forwards each port from 127.0.0.1 to it. Runs until it gets
//       SIGTERM or SIGINT, or AceLinkUI (the parent process) exits.

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("acelinkui-engine: \(message)\n".utf8))
    exit(1)
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("missing command (prepare or run)") }
arguments.removeFirst()

var image: String?
var share: String?
var ports: [UInt16] = []
var engineArguments: [String] = []
while !arguments.isEmpty {
    let option = arguments.removeFirst()
    if option == "--" {
        engineArguments = arguments
        break
    }
    guard let value = arguments.first else { fail("missing value for \(option)") }
    arguments.removeFirst()
    switch option {
    case "--image": image = value
    case "--share": share = value
    case "--port":
        guard let port = UInt16(value) else { fail("invalid port \(value)") }
        ports.append(port)
    default: fail("unknown option \(option)")
    }
}
guard let image = image else { fail("missing --image") }

let engine = EngineVM(imageReference: image)

Task {
    do {
        switch command {
        case "prepare":
            try await engine.prepare()
            exit(0)
        case "run":
            guard let share = share else { fail("missing --share") }
            try await engine.run(
                share: URL(fileURLWithPath: share), ports: ports, engineArguments: engineArguments
            )
        default:
            fail("unknown command \(command)")
        }
    } catch {
        fail(String(describing: error))
    }
}

dispatchMain()
