import React from 'react'
import BigNumber from 'bignumber.js'

function Percent({ value }) {
  const percent = BigNumber(value).times(100)
  return <>{percent.toFixed()}%</>
}

export default Percent
