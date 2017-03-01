module Bosh::Director
  module Jobs
    class UpdateDeployment < BaseJob
      include LockHelper
      include LegacyDeploymentHelper

      @queue = :normal

      def self.job_type
        :update_deployment
      end

      def initialize(manifest_text, cloud_config_id, runtime_config_id, options = {})
        @blobstore = App.instance.blobstores.blobstore
        @manifest_text = manifest_text
        @cloud_config_id = cloud_config_id
        @runtime_config_id = runtime_config_id
        @options = options
        @event_log = Config.event_log
      end

      def dry_run?
        true if @options['dry_run']
      end

      def perform
        logger.info('Reading deployment manifest')
        manifest_hash = YAML.load(@manifest_text)
        logger.debug("Manifest:\n#{@manifest_text}")

        if ignore_cloud_config?(manifest_hash)
          warning = "Ignoring cloud config. Manifest contains 'networks' section."
          logger.debug(warning)
          @event_log.warn_deprecated(warning)
          cloud_config_model = nil
        else
          cloud_config_model = Bosh::Director::Models::CloudConfig[@cloud_config_id]
          if cloud_config_model.nil?
            logger.debug("No cloud config uploaded yet.")
          else
            logger.debug("Cloud config:\n#{cloud_config_model.manifest}")
          end
        end

        runtime_config_model = Bosh::Director::Models::RuntimeConfig[@runtime_config_id]
        if runtime_config_model.nil?
          logger.debug("No runtime config uploaded yet.")
        else
          logger.debug("Runtime config:\n#{runtime_config_model.raw_manifest}")
        end

        @deployment_name = manifest_hash['name']

        previous_releases, previous_stemcells = get_stemcells_and_releases
        context = {}
        parent_id = add_event

        with_deployment_lock(@deployment_name) do
          deployment_plan = nil

          if @options['deploy']
            Bosh::Director::Models::Deployment.find(name: @deployment_name).add_variable_set(:created_at => Time.now)
          end

          deployment_manifest_object = Manifest.load_from_hash(manifest_hash, cloud_config_model, runtime_config_model)

          @notifier = DeploymentPlan::Notifier.new(@deployment_name, Config.nats_rpc, logger)
          @notifier.send_start_event unless dry_run?

          event_log_stage = @event_log.begin_stage('Preparing deployment', 1)
          event_log_stage.advance_and_track('Preparing deployment') do
            planner_factory = DeploymentPlan::PlannerFactory.create(logger)
            deployment_plan = planner_factory.create_from_manifest(deployment_manifest_object, cloud_config_model, runtime_config_model, @options)
            generate_variables_values(deployment_plan.variables, @deployment_name)
            deployment_plan.bind_models
          end

          if deployment_plan.instance_models.any?(&:ignore)
            @event_log.warn('You have ignored instances. They will not be changed.')
          end

          next_releases, next_stemcells = get_stemcells_and_releases
          context = event_context(next_releases, previous_releases, next_stemcells, previous_stemcells)

          begin
            update_instance_plans_variable_set_id(deployment_plan)
            render_templates_and_snapshot_errand_variables(deployment_plan)

            if dry_run?
              return "/deployments/#{deployment_plan.name}"
            else
              deployment_plan.compile_packages

              update_step(deployment_plan).perform

              if check_for_changes(deployment_plan)
                PostDeploymentScriptRunner.run_post_deploys_after_deployment(deployment_plan)
              end

              @notifier.send_end_event
              logger.info('Finished updating deployment')
              add_event(context, parent_id)

              "/deployments/#{deployment_plan.name}"
            end
          ensure
            deployment_plan.job_renderer.clean_cache!
          end
        end
      rescue Exception => e
        begin
          @notifier.send_error_event e unless dry_run?
        rescue Exception => e2
          # log the second error
        ensure
          add_event(context, parent_id, e)
          raise e
        end
      end

      private

      def add_event(context = {}, parent_id = nil, error = nil)
        action = @options.fetch('new', false) ? "create" : "update"
        event = event_manager.create_event(
          {
            parent_id: parent_id,
            user: username,
            action: action,
            object_type: "deployment",
            object_name: @deployment_name,
            deployment: @deployment_name,
            task: task_id,
            error: error,
            context: context
          })
        event.id
      end

      # Job tasks

      def check_for_changes(deployment_plan)
        deployment_plan.instance_groups.each do |job|
          return true if job.did_change
        end
        false
      end

      def update_step(deployment_plan)
        DeploymentPlan::Steps::UpdateStep.new(
          self,
          deployment_plan,
          multi_job_updater(deployment_plan)
        )
      end

      # Job dependencies

      def multi_job_updater(deployment_plan)
        @multi_job_updater ||= begin
          DeploymentPlan::BatchMultiJobUpdater.new(JobUpdaterFactory.new(logger, deployment_plan.job_renderer))
        end
      end

      def update_instance_plans_variable_set_id(deployment_plan)
        deployment_plan.instance_groups.each do |instance_group|
          instance_group.unignored_instance_plans.each do |instance_plan|
            if @options['deploy']
              instance_plan.instance.variable_set = deployment_plan.model.current_variable_set
            else
              instance_plan.instance.variable_set = instance_plan.instance.variable_set
            end
          end
        end
      end

      def render_templates_and_snapshot_errand_variables(deployment_plan)
        errors = render_instance_groups_templates(deployment_plan.instance_groups_starting_on_deploy, deployment_plan.job_renderer)
        errors += snapshot_errands_variables_versions(deployment_plan.errand_instance_groups)

        unless errors.empty?
          message = errors.map { |error| error.message.strip }.join("\n")
          header = 'Unable to render instance groups for deployment. Errors are:'
          raise Bosh::Director::FormatterHelper.new.prepend_header_and_indent_body(header, message, {:indent_by => 2})
        end
      end

      def render_instance_groups_templates(instance_groups, job_renderer)
        errors = []
        instance_groups.each do |instance_group|
          begin
            job_renderer.render_job_instances(instance_group.unignored_instance_plans)
          rescue Exception => e
            errors.push e
          end
        end
        errors
      end

      def snapshot_errands_variables_versions(errands_instance_groups)
        errors = []
        variables_interpolator = ConfigServer::VariablesInterpolator.new

        errands_instance_groups.each do |instance_group|
          instance_group_errors = []

          begin
            variables_interpolator.interpolate_template_spec_properties(instance_group.properties, @deployment_name) # does this need instance variable set or deployment variable set
          rescue Exception => e
            instance_group_errors.push e
          end

          begin
            variables_interpolator.interpolate_link_spec_properties(instance_group.resolved_links || {})
          rescue Exception => e
            instance_group_errors.push e
          end

          unless instance_group_errors.empty?
            message = instance_group_errors.map { |error| error.message.strip }.join("\n")
            header = "- Unable to render jobs for instance group '#{instance_group.name}'. Errors are:"
            e = Exception.new(Bosh::Director::FormatterHelper.new.prepend_header_and_indent_body(header, message, {:indent_by => 2}))
            errors << e
          end
        end
        errors
      end

      def get_stemcells_and_releases
        deployment = current_deployment
        stemcells = []
        releases = []
        if deployment
          releases = deployment.release_versions.map do |rv|
            "#{rv.release.name}/#{rv.version}"
          end
          stemcells = deployment.stemcells.map do |sc|
            "#{sc.name}/#{sc.version}"
          end
        end
        return releases, stemcells
      end

      def current_deployment
        Models::Deployment[name: @deployment_name]
      end

      def event_context(next_releases, previous_releases, next_stemcells, previous_stemcells)
        after_objects = {}
        after_objects['releases'] = next_releases unless next_releases.empty?
        after_objects['stemcells'] = next_stemcells unless next_stemcells.empty?

        before_objects = {}
        before_objects['releases'] = previous_releases unless previous_releases.empty?
        before_objects['stemcells'] = previous_stemcells unless previous_stemcells.empty?

        context = {}
        context['before'] = before_objects
        context['after'] = after_objects
        context
      end

      def generate_variables_values(variables, deployment_name)
        config_server_client = Bosh::Director::ConfigServer::ClientFactory.create(@logger).create_client
        config_server_client.generate_values(variables, deployment_name)
      end
    end
  end
end