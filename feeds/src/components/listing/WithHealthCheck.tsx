import React from 'react'
import { connect, MapStateToProps } from 'react-redux'
import classNames from 'classnames'
import { AppState } from 'state'

interface StateProps {
  healthCheck: any
}

interface OwnProps {
  item: any
  compareOffchain?: boolean
  enableHealth: boolean
  Component: any
}

interface Props extends StateProps, OwnProps {}

interface Status {
  result: string
  errors: string[]
}

const WithHealthCheck: React.FC<Props> = ({
  enableHealth,
  healthCheck,
  compareOffchain,
  item,
  Component,
}) => {
  const status = normalizeStatus(item, healthCheck)
  const tooltipErrors = `${
    status.result === 'error' ? ':' : ''
  } ${status.errors.join(', ')}`
  const title = `${status.result}${tooltipErrors}`
  let classes: any

  if (enableHealth) {
    classes = classNames(
      'listing-grid__item',
      healthClasses(status, enableHealth),
    )
  }

  return (
    <Component
      key={item.config.name}
      className={classes}
      title={title}
      item={item}
      compareOffchain={compareOffchain}
    />
  )
}

function healthClasses(status: Status, enableHeath: boolean) {
  if (!enableHeath) {
    return
  }
  if (status.result === 'unknown') {
    return 'listing-grid__item--health-unknown'
  }
  if (status.result === 'error') {
    return 'listing-grid__item--health-error'
  }

  return 'listing-grid__item--health-ok'
}

function normalizeStatus(item: any, healthCheck: any): Status {
  const errors: string[] = []

  if (item.answer === undefined || healthCheck === undefined) {
    return { result: 'unknown', errors }
  }

  const thresholdDiff = healthCheck.currentPrice * (item.config.threshold / 100)
  const thresholdMin = Math.max(healthCheck.currentPrice - thresholdDiff, 0)
  const thresholdMax = healthCheck.currentPrice + thresholdDiff
  const withinThreshold =
    item.answer >= thresholdMin && item.answer < thresholdMax

  if (item.answer === 0) {
    errors.push('answer price is 0')
  }
  if (!withinThreshold) {
    errors.push(
      `reference contract price is not within threshold ${thresholdMin} - ${thresholdMax}`,
    )
  }

  if (errors.length === 0) {
    return { result: 'ok', errors }
  } else {
    return { result: 'error', errors }
  }
}

const mapStateToProps: MapStateToProps<StateProps, OwnProps, AppState> = (
  state,
  ownProps,
) => {
  const contractAddress = ownProps.item.config.contractAddress
  const healthCheck = state.listing.healthChecks[contractAddress]
  return { healthCheck }
}

export default connect(mapStateToProps)(WithHealthCheck)
