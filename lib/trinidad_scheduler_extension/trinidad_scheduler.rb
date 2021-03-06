require 'trinidad_scheduler_extension/quartz/job_detail'
require 'trinidad_scheduler_extension/quartz/job_factory'
require 'trinidad_scheduler_extension/quartz/job_error'
require 'trinidad_scheduler_extension/quartz/scheduled_job'

module TrinidadScheduler

  JobDetail = Quartz::JobDetail
  JobFactory = Quartz::JobFactory
  ScheduledJob = Quartz::ScheduledJob
  # AppJob = Quartz::AppJob

  #def self.Cron(*args); Quartz::Cron(*args) end
  #def self.Simple(*args); Quartz::Simple(*args) end
  #def self.DateInterval(*args); Quartz::DateInterval(*args) end

  CONFIG_HOME = File.expand_path('config', File.dirname(__FILE__))

  # Sets log4j properties if not established by Application Servers
  # TrinidadScheduler is really lazy so this is only set when a scheduler is needed
  def self.initialize_configuration! # TODO avoid Log4J by default by using JUL
    unless Java::JavaLang::System.getProperty('log4j.configuration')
      log4j_properties = Java::JavaIo::File.new("#{CONFIG_HOME}/log4j.properties")
      Java::JavaLang::System.setProperty('log4j.configuration', log4j_properties.to_url.to_s)
    end
  end

  # Standardizing the naming of the variables that are stored on the context
  # @deprecated use {#context_name} instead
  def self.context_path(path)
    path.gsub("/", "") == "" ? "Default" : path.gsub("/", "").capitalize
  end

  def self.context_name(context)
    path = context.respond_to?(:context_path) ? context.context_path : ''
    path.gsub!("/", ""); return path.empty? ? "Default" : path.capitalize
  end

  def self.scheduler(context)
    raise "no context given" unless context
    context.get_attribute(scheduler_name(context)) || nil
  end

  def self.scheduler!(context)
    scheduler(context) || raise("no scheduler exists for: #{context}")
  end

  # Assists in lazily evaluating if a scheduler is needed for a context
  #
  # @param [ServletContext] context
  # @return [Boolean]
  def self.scheduler_exists?(context)
    !!scheduler(context)
  end

  # Tomcat event callbacks are good for static systems but JRuby allows dynamic definition of classes and function
  # so I am storing a variable on the servlet context that allow the extension to check if the servlet has been started
  # during lazy evaluation of the need for a scheduler and/or starting the scheduler
  #
  # @param [ServletContext] context
  # @return [Boolean]
  def self.servlet_started?(context)
    !!context.get_attribute(started_name(context))
  end

  # Helper to centralize the operations on the servlet contexts, sets the servlet started variable when the context is started, reguardless of whether
  # a scheduler exists or not
  #
  # @param [ServletContext] context
  def self.set_servlet_started(context)
    context.set_attribute(started_name(context), true)
  end

  # Helper method that attaches the configuration options from the Trinidad config file to the ServletContext
  #
  # @param [ServletContext] context
  # @param [Hash] options
  def self.store_scheduler_options(context, options)
    context.set_attribute(options_name(context), options)
  end

  # Retrieve the stored configuration options from the ServletContext.
  #
  # @param [ServletContext] context
  # @return [Hash]
  def self.fetch_scheduler_options(context)
    return nil unless options = context.get_attribute(options_name(context))
    symbolized = Hash.new
    options.each { |key, val| symbolized[key.to_s.to_sym] = val }
    symbolized
  end

  # Centralized definition of where variables will be stored on the ServletContext
  def self.started_name(context)
    "TrinidadScheduler::#{context_name(context)}::ServletStarted"
  end

  def self.options_name(context)
    "TrinidadScheduler::#{context_name(context)}::SchedulerOptions"
  end

  def self.scheduler_name(context)
    "TrinidadScheduler::#{context_name(context)}::Scheduler"
  end

  # Bracket accessor defined to retreive the scheduler for a context
  # if no scheduler is attached to the context then one is created and attached at time of access and returned
  #
  # @param [ServletContext] context
  # @return [org.quartz.impl.StdScheduler]
  def self.[](context)
    unless scheduler_exists?(context)
      self.initialize_configuration!
      self[context] = quartz_scheduler(context)
    end

    if servlet_started?(context) && scheduler = scheduler!(context)
      unless scheduler.started?
        scheduler.start
        scheduler.resume_all
      end
    end

    scheduler
  end

  # Bracket assignment operator, will attach the scheduler passed to the context in the brackets
  #
  # @param [ServletContext] context
  # @param [org.quartz.impl.StdScheduler] scheduler
  def self.[]=(context, scheduler)
    context.set_attribute(scheduler_name(context), scheduler)
  end

  # Method to build and return Quartz schedulers
  #
  # @param [ServletContext] context
  # @param [Hash] opts, the options to configure the scheduler with
  # @private
  def self.quartz_scheduler(context, options = fetch_scheduler_options(context))
    name = options.delete(:name) || context_name(context)

    scheduler_factory = org.quartz.impl.StdSchedulerFactory.new
    scheduler_factory.initialize(quartz_properties(name, options))

    scheduler = scheduler_factory.get_scheduler
    scheduler.set_job_factory(TrinidadScheduler::JobFactory.new)
    scheduler.pause_all
    scheduler
  end

  # @private
  def self.quartz_properties(name, options = {})
    defaults = {
      'org.quartz.scheduler.instanceName' => "Quartz::#{name}::Application",
      'org.quartz.scheduler.rmi.export' => false, 'org.quartz.scheduler.rmi.proxy' => false,
      'org.quartz.threadPool.class' => 'org.quartz.simpl.SimpleThreadPool',
      'org.quartz.threadPool.threadNamePrefix' => "Quartz::#{name}::Worker",
      'org.quartz.threadPool.threadsInheritContextClassLoaderOfInitializingThread' => true,
      'org.quartz.jobStore.class' => 'org.quartz.simpl.RAMJobStore',
      'org.quartz.jobStore.misfireThreshold' => 60000,
    }

    # to interrupt jobs if they are still in execution when shutting down :
    interrupt_on_shutdown = options.delete(:interrupt_on_shutdown)
    unless interrupt_on_shutdown.nil?
      defaults['org.quartz.scheduler.interruptJobsOnShutdown'] = !! interrupt_on_shutdown
    end
    wrap_in_user_tx = options.key?(:wrapped) ? options.delete(:wrapped) : options.delete(:wrap_in_user_transaction)
    unless wrap_in_user_tx.nil?
      defaults['org.quartz.scheduler.wrapJobExecutionInUserTransaction'] = !! wrap_in_user_tx
    end

    if thread_count = options.delete(:thread_count) || options.delete(:'threadPool.threadCount')
      defaults['org.quartz.threadPool.threadCount'] = thread_count
    end
    if thread_priority = options.delete(:thread_priority) || options.delete(:'threadPool.threadPriority')
      defaults['org.quartz.threadPool.threadPriority'] = thread_priority
    end

    options.each do |key, value|
      key = key.to_s; next unless key.index('.')
      # qualify e.g. 'jobStore.class' -> 'org.quartz.jobStore.class'
      key = "org.quartz.#{key}" unless key.index('org.quartz.')
      defaults[key] = value unless defaults.key?(key)
    end

    properties = Java::JavaUtil::Properties.new
    defaults.each { |key, value| properties.setProperty(key, value.to_s) unless value.nil? }
    properties
  end

end
