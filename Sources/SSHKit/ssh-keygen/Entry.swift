import SSHKeygenCommand

@main
struct Entry {
    static func main() async {
        await SSHKeygenCommand.main()
    }
}
