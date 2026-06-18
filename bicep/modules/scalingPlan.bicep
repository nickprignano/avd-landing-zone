// Scaling plan — ramp hosts up before the workday, down after hours,
// off overnight. Schedule below is a sensible DEFAULT; tuning it to your
// org's real usage is the cost-optimization work (out of scope here).
// Wraps the AVM scaling-plan module.

param name string
param location string
param tags object

@description('Resource ID of the host pool this plan drives.')
param hostPoolResourceId string

@description('Time zone for the schedule.')
param timeZone string = 'Eastern Standard Time'

module scalingPlan 'br/public:avm/res/desktop-virtualization/scaling-plan:0.4.0' = {
  name: 'deploy-scalingplan'
  params: {
    name: name
    location: location
    tags: tags
    hostPoolType: 'Pooled'
    timeZone: timeZone
    schedules: [
      {
        name: 'weekday'
        daysOfWeek: ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday']
        rampUpStartTime: { hour: 7, minute: 0 }
        rampUpLoadBalancingAlgorithm: 'BreadthFirst'
        rampUpMinimumHostsPct: 20
        rampUpCapacityThresholdPct: 60
        peakStartTime: { hour: 9, minute: 0 }
        peakLoadBalancingAlgorithm: 'BreadthFirst'
        rampDownStartTime: { hour: 18, minute: 0 }
        rampDownLoadBalancingAlgorithm: 'DepthFirst'
        rampDownMinimumHostsPct: 10
        rampDownCapacityThresholdPct: 90
        rampDownForceLogoffUsers: false
        rampDownWaitTimeMinutes: 30
        rampDownNotificationMessage: 'You will be logged off soon. Please save your work.'
        rampDownStopHostsWhen: 'ZeroSessions'
        offPeakStartTime: { hour: 20, minute: 0 }
        offPeakLoadBalancingAlgorithm: 'DepthFirst'
      }
    ]
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolResourceId
        scalingPlanEnabled: true
      }
    ]
  }
}

output resourceId string = scalingPlan.outputs.resourceId
