#!/usr/bin/env ts-node

import * as fs from 'fs'
import {Command, flags} from '@oclif/command'

class GenerateFeeds extends Command {
  static description =
    'Generate feeds.json file from reference data directory'

  static examples =
    '$ generate_feeds <path_to_input_file> <path_to_output_file>'

  static flags = {
    version: flags.version(),
    help: flags.help(),
  }

  async run() {
    const {flags} = this.parse(LS)
    let files = fs.readdirSync(flags.dir)
    for (let f of files) {
      this.log(f)
    }
  }
}

LS.run()
.catch(require('@oclif/errors/handle'))
