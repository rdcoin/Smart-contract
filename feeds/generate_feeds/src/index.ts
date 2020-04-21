import {fs} from 'fs'
import {Command, flags} from '@oclif/command'
import DirectoryFileProcessor from './directory_file_processor'

class GenerateFeeds extends Command {
  static description = 'Generate feeds.json file from reference data directory'

  static flags = {
    // add --version flag to show CLI version
    version: flags.version({char: 'v'}),
    help: flags.help({char: 'h'}),
  }

  static args = [
    {
      name: 'input_file',
      required: true,
      description: 'Input file (e.g. directory.json)',
    },
    {
      name: 'output_file',
      required: true,
      description: 'Output file (e.g. feeds.json)',
    }
  ]

  async run() {
    const {args, flags} = this.parse(GenerateFeeds)

    this.log(`Reading ${args.input_file} and writing to ${args.output_file}`)
    let data = fs.readFileSync(args.input_file)
    let contractsAndOperators = JSON.parse(data)

    const processor = new DirectoryFileProcessor(contractsAndOperators)
    const output = processor.process()
    fs.writeFileSync(args.output_file, JSON.stringify(output))
  }
}

export = GenerateFeeds
